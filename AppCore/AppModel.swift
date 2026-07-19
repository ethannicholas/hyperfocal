// Portability: AppCore must compile on Linux (cross-platform plan) — no
// SwiftUI/AppKit here, CoreGraphics only behind canImport (the CGRect/
// CGSize geometry types come from Foundation everywhere), and Combine
// swaps for OpenCombine off-Apple.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
#if canImport(os)
import os
#endif
import HyperfocalKit

/// Shared zoom/pan state for the synced preview panes. Offsets are in image
/// pixels (input and output share dimensions), so both panes track exactly.
@MainActor
final class ViewportState: ObservableObject {

    enum ZoomMode: Equatable {
        case fit
        case scale(CGFloat)  // view points per image pixel
    }

    static let fixedLevels: [CGFloat] = [0.0625, 0.125, 0.25, 0.5, 1, 2, 4]

    static func percentLabel(_ scale: CGFloat) -> String {
        let pct = scale * 100
        return pct == pct.rounded()
            ? String(format: "%.0f%%", pct)
            : String(format: "%.4g%%", pct)
    }

    @Published var mode: ZoomMode = .fit
    @Published var offset: CGSize = .zero  // image-pixel displacement of center

    /// Last known pane size, maintained by the event overlay; used to convert
    /// fit → absolute when zooming via buttons/menu.
    var lastPaneSize = CGSize(width: 700, height: 700)

    func effectiveScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        switch mode {
        case .fit:
            guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
            return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        case .scale(let s):
            return s
        }
    }

    /// One zoom range for every zoom path (buttons, pinch, cursor-anchored).
    static let scaleRange: ClosedRange<CGFloat> = 0.01...16

    func zoom(by factor: CGFloat, imageSize: CGSize) {
        let current = effectiveScale(imageSize: imageSize, viewSize: lastPaneSize)
        mode = .scale(min(max(current * factor, Self.scaleRange.lowerBound),
                          Self.scaleRange.upperBound))
    }

    /// Zoom anchored at a cursor location (pane coordinates, top-left origin):
    /// the image point under the cursor stays put.
    func zoom(at location: CGPoint, in paneSize: CGSize, by factor: CGFloat, imageSize: CGSize) {
        let oldScale = effectiveScale(imageSize: imageSize, viewSize: paneSize)
        let newScale = min(max(oldScale * factor, Self.scaleRange.lowerBound),
                           Self.scaleRange.upperBound)
        guard newScale != oldScale else { return }
        let dx = location.x - paneSize.width / 2
        let dy = location.y - paneSize.height / 2
        offset.width += dx * (1 / oldScale - 1 / newScale)
        offset.height += dy * (1 / oldScale - 1 / newScale)
        mode = .scale(newScale)
        clampOffset(imageSize: imageSize)
    }

    func pan(by deltaView: CGSize, imageSize: CGSize, paneSize: CGSize) {
        let scale = effectiveScale(imageSize: imageSize, viewSize: paneSize)
        guard scale > 0 else { return }
        offset.width -= deltaView.width / scale
        offset.height -= deltaView.height / scale
        clampOffset(imageSize: imageSize)
    }

    func reset() {
        mode = .fit
        offset = .zero
    }

    func clampOffset(imageSize: CGSize) {
        offset.width = min(max(offset.width, -imageSize.width / 2), imageSize.width / 2)
        offset.height = min(max(offset.height, -imageSize.height / 2), imageSize.height / 2)
    }
}

/// Engine log lines (`log show --predicate 'subsystem == "org.hyperfocal"'`).
/// Per-frame progress is debug-level chatter; everything else — disk-cache
/// skips and failures, exclusions, stage summaries — persists at notice.
/// File-scope (not on AppModel) so it's nonisolated: the pipeline calls it
/// from the fusion thread, and Logger is thread-safe.
private let fusionLog = Logger(subsystem: "org.hyperfocal", category: "fusion")
private func logFusion(_ line: String) {
    if line.contains(" pass ") {
        fusionLog.debug("\(line, privacy: .public)")
    } else {
        fusionLog.notice("\(line, privacy: .public)")
    }
}

@MainActor
public final class AppModel: ObservableObject {

    public enum Phase: Equatable {
        case empty
        case loaded
        case running
        case done
        case failed(String)

        public var isRunning: Bool { self == .running }
    }

    public enum OutputMode: String, CaseIterable {
        case result = "Result"
        case depth = "Depth"
    }

    public enum ExportFormat: String, CaseIterable, Identifiable {
        case tiff = "TIFF (16-bit)"
        case dng = "DNG (raw)"
        case png = "PNG (16-bit)"
        case jpeg = "JPEG"

        public var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .tiff: return "tif"
            case .dng: return "dng"
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    public enum ExportColorSpace: String, CaseIterable, Identifiable {
        case srgb = "sRGB"
        case displayP3 = "Display P3"
        case prophoto = "ProPhoto RGB"

        public var id: String { rawValue }

        #if canImport(CoreGraphics)
        var cgColorSpace: CGColorSpace? {
            switch self {
            case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)
            case .displayP3: return nil  // the working space; no conversion
            case .prophoto: return CGColorSpace(name: CGColorSpace.rommrgb)
            }
        }
        #endif

        /// Portable export-space token for the non-Apple encode path
        /// (lcms2); nil keeps the Display-P3 working space — the CLI's
        /// ColorSpaceChoice pattern.
        var portableName: String? {
            switch self {
            case .srgb: return "srgb"
            case .displayP3: return nil
            case .prophoto: return "prophoto"
            }
        }
    }

    /// Bridges the per-platform ImageFile.save signature (CGColorSpace on
    /// Apple, a portable space name elsewhere) — the CLI's saveFused
    /// pattern. Takes the enum (Sendable) so detached export tasks can
    /// carry it without touching the model.
    nonisolated static func saveImage(_ image: ImageBuffer, to url: URL,
                                      sourceFrame: URL?,
                                      colorSpace: ExportColorSpace) throws {
        #if canImport(CoreGraphics)
        try ImageFile.save(image, to: url, sourceFrame: sourceFrame,
                           colorSpace: colorSpace.cgColorSpace)
        #else
        try ImageFile.save(image, to: url, sourceFrame: sourceFrame,
                           colorSpaceName: colorSpace.portableName)
        #endif
    }

    @Published public var phase: Phase = .empty
    @Published public var frames: [URL] = []
    @Published public var included: Set<URL> = []
    @Published public var selection: Set<URL> = []
    /// Frames the last fuse flagged as bad, with the reason ("4.1× darker than
    /// the stack") — shown as a warning badge in the Stack list. Excluded
    /// frames stay listed with their checkbox cleared, so opting back in is
    /// just re-checking them.
    @Published public var frameIssues: [URL: String] = [:]
    /// Decides whether flagged frames get excluded (called off the main thread
    /// with display lines). Defaults to a blocking alert; the headless probe
    /// replaces it. Read once at fuse start.
    var badFramePrompt: (([String]) -> Bool)?

    // Multi-stack project. AppModel's frame/result fields below always mirror
    // the *selected* stack (so the whole single-stack pipeline — fuse,
    // retouch, preview — operates unchanged); `selectStack` stashes the
    // mirrors into the outgoing Stack and installs the incoming one.
    @Published public private(set) var stacks: [Stack] = []
    @Published public var selectedStackID: UUID?
    @Published public var expandedStacks: Set<UUID> = []
    var selectedStack: Stack? { stacks.first { $0.id == selectedStackID } }

    public enum StackStatus {
        case unfused, fusing, fused, failed(String)
    }

    // Queue ("Fuse Enabled Stacks") progress prefix, e.g. "Stack 2 of 5 · ".
    @Published public var batchStatus: String?
    private var batchMode = false
    /// Probe overrides: answer the burst-split question ((directory name,
    /// burst count) → load as separate stacks?); receive queue/export
    /// summaries instead of an alert.
    var splitChoicePrompt: ((String, Int) -> Bool)?
    var queueSummaryPresenter: ((String) -> Void)?

    // Settings persist in an explicit suite: an unbundled executable's standard
    // defaults domain is its *process name*, which changed with each rename —
    // orphaning saved values. The suite survives renames and future bundling.
    // Deliberately decoupled from the bundle ID (renaming the suite orphans
    // saved settings). UI-test runs get their own throwaway suite so tests
    // can toggle sections/settings without polluting the user's real state.
    // HYPERFOCAL_SETTINGS_SUITE overrides the suite outright — the Qt
    // shell names its own store there so the two shells' settings never
    // bleed into each other (same isolation idea as the UI-test suite).
    static let settings = UserDefaults(
        suiteName: ProcessInfo.processInfo.environment["HYPERFOCAL_SETTINGS_SUITE"]
            ?? (ProcessInfo.processInfo.environment["HYPERFOCAL_UITEST"] == "1"
                ? "org.hyperfocal.uitest-settings"
                : "org.hyperfocal.settings")) ?? .standard

    // Fusion parameters
    @Published public var alignFrames: Bool {
        didSet { Self.settings.set(alignFrames, forKey: "alignFrames") }
    }
    @Published public var useGPU: Bool {
        didSet { Self.settings.set(useGPU, forKey: "useGPU") }
    }
    /// Fusion's temporary disk cache (FrameSpill): caches aligned frames
    /// between the two depth-fusion passes so the stack isn't decoded twice.
    /// Output is bit-identical either way — the toggle exists for machines
    /// short on disk (the cache is width×height×16 bytes per frame).
    @Published public var fusionDiskCache: Bool {
        didSet { Self.settings.set(fusionDiskCache, forKey: "fusionDiskCache") }
    }
    // The fusion sliders are per-project creative controls, deliberately
    // not persisted: with the defaults dialed in, every new project starts
    // from them (the set-and-forget switches below stay persisted).
    @Published public var sharpnessSigma = defaultSharpnessSigma
    @Published public var noiseFloor: Double = AppModel.defaultNoiseFloor {
        didSet {
            if noiseFloorPreviewActive { updateNoiseFloorPreview() }
        }
    }
    @Published public var medianRadius = defaultMedianRadius
    @Published public var blendRadius = defaultBlendRadius
    @Published public var normalizeExposure: Bool {
        didSet { Self.settings.set(normalizeExposure, forKey: "normalizeExposure") }
    }
    /// Order each stack's frames by EXIF capture time at load (filename
    /// order breaks when the camera's file counter rolls over mid-stack).
    /// Off = filename always wins. Read at load time, not fuse time.
    @Published public var orderByCaptureTime: Bool {
        didSet { Self.settings.set(orderByCaptureTime, forKey: "orderByCaptureTime") }
    }
    /// Sidebar sections the user has collapsed — persisted like the other
    /// set-and-forget UI preferences.
    enum SidebarSection: String, CaseIterable {
        case stack, fusion, tone, retouch, export
    }
    @Published var collapsedSections: Set<SidebarSection> {
        didSet {
            Self.settings.set(collapsedSections.map(\.rawValue).sorted(),
                              forKey: "collapsedSections")
        }
    }

    func isCollapsed(_ section: SidebarSection) -> Bool {
        collapsedSections.contains(section)
    }

    func toggleSection(_ section: SidebarSection) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    // Progress
    @Published public var stageText = ""
    @Published public var stageFraction = 0.0
    // Remaining-time estimate for the current stage, extrapolated from its
    // fraction. Stage-scoped on purpose: stages have wildly different
    // per-unit costs, so a whole-fuse extrapolation would swing hardest
    // exactly when it's most visible (the long depth/render stages).
    @Published public var stageETA: String?
    private var stageTimerStage: FusionProgress.Stage?
    private var stageTimerStart = Date()
    @Published public var progressive: PlatformImage?
    @Published public var progressiveNominalSize: CGSize?
    /// True while `progressive` holds a data visualization — the aligner's
    /// gradient-magnitude image or the depth map forming — rather than the
    /// render accumulating. Only render-stage previews are image pixels;
    /// the panes must not tone anything else.
    @Published public private(set) var progressiveIsData = false
    @Published public var processingSource: PlatformImage?
    @Published public var processingSourceLabel: String?
    @Published public var processingSourceNominalSize: CGSize?

    // Results & previews
    @Published public var outputPreview: PlatformImage?
    @Published public var depthPreview: PlatformImage?
    @Published public var inputPreview: PlatformImage?
    @Published public var inputPreviewURL: URL?
    /// The preview is warped into the fused canvas (alignment transforms
    /// existed when it was decoded) rather than the raw file.
    @Published public var inputPreviewAligned = false
    /// A decode for the selected frame is in flight; until it lands,
    /// `inputPreview` still shows the previous image (public: the bridge
    /// reports it so shells and journeys can wait out the swap).
    @Published public private(set) var inputPreviewLoading = false
    /// Why the selected frame couldn't be shown (missing file, decode failure).
    /// Without this the pane falls back to the "select a frame" hint, which is
    /// misleading when a frame IS selected but its volume is unmounted.
    @Published var inputPreviewError: String?
    /// True pixel dimensions of the input preview (the preview CGImage may be
    /// a reduced-resolution bitmap stretched to this size).
    @Published var inputPixelSize: CGSize?
    @Published public var outputMode: OutputMode = .result
    /// Lightroom-style tone adjustments (per stack, saved in projects):
    /// live on every preview — panes and retouch canvas — and baked into
    /// TIFF/PNG/JPEG exports at full float precision before quantization.
    /// Linear DNG ignores them by design: that format hands unmodified
    /// linear data to a real raw developer.
    @Published public var tone = ToneSettings() {
        didSet {
            guard oldValue != tone else { return }
            if !installingStack { hasUnsavedWork = true }
        }
    }
    /// Non-destructive output crop for the selected stack, in result-canvas
    /// pixels (nil = full canvas). Applies to every export, the animation,
    /// and the panes; saved per stack in the project.
    @Published public var cropRect: CGRect? {
        didSet {
            guard oldValue != cropRect else { return }
            if !installingStack { hasUnsavedWork = true }
        }
    }
    /// Crop rotation in degrees about the rect's center (0 = axis-aligned).
    @Published public var cropAngle: Double = 0 {
        didSet {
            guard oldValue != cropAngle else { return }
            if !installingStack { hasUnsavedWork = true }
        }
    }
    /// Guards `tone.didSet` against marking stack switches as unsaved edits.
    private var installingStack = false
    /// Rocking-animation parallax strength, chosen in the export dialog.
    public enum AnimationStrength: String, CaseIterable {
        case subtle = "Subtle"
        case medium = "Medium"
        case strong = "Strong"
        /// Peak disparity as a fraction of the video width.
        var amplitude: Double {
            switch self {
            case .subtle: return 0.005
            case .medium: return 0.01
            case .strong: return 0.02
            }
        }
    }
    @Published public var animationStrength: AnimationStrength {
        didSet { Self.settings.set(animationStrength.rawValue, forKey: "animationStrength") }
    }

    /// Animation container. GIF exists because it's the only format whose
    /// loop-forever flag every viewer honors; MP4 plays once unless the
    /// player is told to loop.
    public enum AnimationFormat: String, CaseIterable {
        case mp4 = "MP4 (H.264)"
        case gif = "GIF (loops automatically)"
        var fileExtension: String { self == .gif ? "gif" : "mp4" }
    }
    @Published public var animationFormat: AnimationFormat {
        didSet { Self.settings.set(animationFormat.rawValue, forKey: "animationFormat") }
    }

    /// The viewpoint's motion (Zerene's path options).
    public enum AnimationPath: String, CaseIterable {
        case horizontal = "Rock left–right"
        case vertical = "Rock up–down"
        case circular = "Circle"
        var enginePath: RockingAnimation.Path {
            switch self {
            case .horizontal: return .horizontal
            case .vertical: return .vertical
            case .circular: return .circular
            }
        }
    }
    @Published public var animationPath: AnimationPath {
        didSet { Self.settings.set(animationPath.rawValue, forKey: "animationPath") }
    }

    public enum AnimationDuration: String, CaseIterable {
        case two = "2 seconds"
        case three = "3 seconds"
        case four = "4 seconds"
        case six = "6 seconds"
        var seconds: Double {
            switch self {
            case .two: return 2
            case .three: return 3
            case .four: return 4
            case .six: return 6
            }
        }
    }
    @Published public var animationDuration: AnimationDuration {
        didSet { Self.settings.set(animationDuration.rawValue, forKey: "animationDuration") }
    }

    enum AnimationFPS: String, CaseIterable {
        case cinema = "24 fps"
        case standard = "30 fps"
        case smooth = "60 fps"
        var value: Double {
            switch self {
            case .cinema: return 24
            case .standard: return 30
            case .smooth: return 60
            }
        }
    }
    @Published var animationFPS: AnimationFPS {
        didSet { Self.settings.set(animationFPS.rawValue, forKey: "animationFPS") }
    }

    @Published public var exportFormat: ExportFormat {
        didSet { Self.settings.set(exportFormat.rawValue, forKey: "exportFormat") }
    }
    @Published public var exportColorSpace: ExportColorSpace {
        didSet { Self.settings.set(exportColorSpace.rawValue, forKey: "exportColorSpace") }
    }

    let viewport = ViewportState()
    private let alignmentCache = AlignmentCache()

    // Retouching
    @Published public var retouchMode = false
    @Published public var retouch: RetouchSession?
    private(set) var resultDepth: [Float] = []
    private(set) var resultSharpness: FrameSharpness?
    // Exposure gains the fusion applied; retouch sources must match them.
    private(set) var resultGains: [SIMD3<Float>]?
    private var fuseURLs: [URL] = []
    // What the current result was fused with (selected-stack mirror).
    private var fusedSettings: FuseSettings?

    private var fusionCancellation: CancellationToken?

    // Noise-floor preview: while the slider is dragged, the output pane shows
    // the depth map the new floor would produce — the *actual* regularizer
    // (argmax → confidence threshold → weighted median → jump-flood fill →
    // cleanup) run on the retained low-res sharpness planes. Below-floor
    // regions inheriting smoothly from their surroundings is normal and
    // harmless; blotchy fill basins or halos standing off edges are what the
    // slider is there to fix. (The old preview blacked out sub-floor pixels,
    // which read as "problem here" even when the fill would be fine.)
    @Published public var noiseFloorPreview: PlatformImage?
    private var noiseFloorPreviewData:
        (energyMax: [Float], argmax: [Float], concentration: [Float],
         planes: [[Float]], guide: [Float], width: Int, height: Int,
         halfWidth: Int, frames: Int)?
    /// Bumped per compute and on end; compute tasks poll it from worker
    /// threads (hence the lock, not a plain Int) to abort a fit whose result
    /// would be discarded — a stale in-flight fit ends within one tier-2 row
    /// instead of running to completion.
    private let noiseFloorPreviewGeneration = LockedCounter()
    /// One compute in flight at a time; a drag tick arriving mid-compute is
    /// coalesced into a single follow-up with the latest slider value. The
    /// guided fit costs hundreds of ms at deep-stack scale — unbounded
    /// per-tick tasks would thrash and starve the display.
    private var noiseFloorPreviewComputing = false
    private var noiseFloorPreviewPending = false
    /// The one-time preview-data build also runs off-main; these keep it
    /// single-flight and let stack switches / re-fuses orphan a stale build.
    private var noiseFloorPreviewBuilding = false
    private var noiseFloorPreviewDataEpoch = 0
    /// True between begin/end (slider engaged) — the data cache outlives the
    /// drag, but renders must not.
    private var noiseFloorPreviewActive = false

    // Retouch edits restored from a saved session (consumed by enterRetouch).
    private var savedWorking: ImageBuffer?
    private var savedSourceIndex: Int?

    /// A fused result (or retouch edits on one) exists that no project file
    /// holds. Set by fuse completion and retouch strokes, cleared by saving
    /// or opening a project; quitting with it set asks for confirmation.
    public private(set) var hasUnsavedWork = false
    /// The file the current project was opened from or last saved to —
    /// File > Save writes straight back to it; nil (never saved, or project
    /// closed) makes Save fall through to Save As. The open/save panels'
    /// sandbox grants cover the URL for the app's lifetime, so in-place
    /// re-saves need no new grant. Published: the window title shows it.
    @Published public private(set) var projectURL: URL?

    // Security-scoped file access (the app is sandboxed; frames live outside
    // the container). `grantedRoots` are the URLs the user granted this
    // session — open-panel/drop selections, or bookmark-resolved roots after
    // a restore — and are what gets bookmarked into saved projects.
    // `scopedAccessURLs` are the roots we called startAccessing... on,
    // balanced with stopAccessing when the project is replaced.
    private var grantedRoots: [URL] = []
    private var scopedAccessURLs: [URL] = []

    public init() {
        let d = Self.settings
        animationStrength = d.string(forKey: "animationStrength")
            .flatMap { AnimationStrength(rawValue: $0) } ?? .medium
        animationFormat = d.string(forKey: "animationFormat")
            .flatMap { AnimationFormat(rawValue: $0) } ?? .mp4
        animationPath = d.string(forKey: "animationPath")
            .flatMap { AnimationPath(rawValue: $0) } ?? .horizontal
        animationDuration = d.string(forKey: "animationDuration")
            .flatMap { AnimationDuration(rawValue: $0) } ?? .three
        animationFPS = d.string(forKey: "animationFPS")
            .flatMap { AnimationFPS(rawValue: $0) } ?? .standard
        exportFormat = d.string(forKey: "exportFormat")
            .flatMap { ExportFormat(rawValue: $0) } ?? .tiff
        exportColorSpace = d.string(forKey: "exportColorSpace")
            .flatMap { ExportColorSpace(rawValue: $0) } ?? .srgb
        alignFrames = d.object(forKey: "alignFrames") as? Bool ?? true
        #if canImport(Metal)
        useGPU = (d.object(forKey: "useGPU") as? Bool ?? true) && MetalEngine.shared != nil
        #else
        useGPU = false
        #endif
        fusionDiskCache = d.object(forKey: "fusionDiskCache") as? Bool ?? true
        for legacy in ["sharpnessSigma", "noiseFloor", "medianRadius",
                       "blendRadius", "slabDeepStacks"] {
            d.removeObject(forKey: legacy)  // sliders no longer persist; slabbing removed
        }
        normalizeExposure = d.object(forKey: "normalizeExposure") as? Bool ?? true
        orderByCaptureTime = d.object(forKey: "orderByCaptureTime") as? Bool ?? true
        collapsedSections = Set((d.stringArray(forKey: "collapsedSections") ?? [])
            .compactMap(SidebarSection.init))

        // One-time cleanup: earlier builds autosaved the whole project on quit
        // (hundreds of MB of pixel blobs — the write took too long, which is
        // why quit now warns about unsaved work instead). The old file lingers
        // for anyone upgrading past that.
        try? FileManager.default.removeItem(at: ProjectStore.autosaveURL)
        // Slabbing (removed 2026-07-15) left per-fuse image directories
        // behind in Application Support; clear the whole tree once.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at: support.appendingPathComponent("Hyperfocal/Slabs"))
        }
    }

    // MARK: - Security-scoped access

    private static let bookmarkLog = Logger(subsystem: "org.hyperfocal",
                                            category: "bookmarks")


    /// Bookmarks for every granted root that covers a current frame. Created
    /// fresh on each save, so stale bookmarks self-heal and folder moves are
    /// re-tracked. Creation failures don't block the save (the pixel data
    /// matters more than the re-link), but they are logged — a project with
    /// no bookmarks can't reach its frames after relaunch, which is worth
    /// diagnosing, not swallowing.
    private func currentBookmarks() -> [String: Data]? {
        #if !os(macOS)
        // No sandbox off macOS: projects carry plain paths, and loads
        // resolve them directly (plan Phase 3's "plain-path bookmarks").
        return nil
        #else
        var bookmarks = [String: Data]()
        let allFrames = Set(stacks.flatMap(\.frames)).union(frames)
        Self.bookmarkLog.notice("save: \(self.grantedRoots.count) granted root(s)")
        func bookmark(_ url: URL) -> Bool {
            if bookmarks[url.path] != nil { return true }
            do {
                let data = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
                bookmarks[url.path] = data
                Self.bookmarkLog.notice(
                    "bookmarked \(url.path, privacy: .public) (\(data.count) bytes)")
                return true
            } catch {
                Self.bookmarkLog.error(
                    "bookmark FAILED for \(url.path, privacy: .public): \(error as NSError, privacy: .public)")
                return false
            }
        }
        for root in grantedRoots {
            let covered = allFrames.filter {
                $0.path == root.path || $0.path.hasPrefix(root.path + "/")
            }
            guard !covered.isEmpty else {
                Self.bookmarkLog.notice(
                    "root covers no frames, skipped: \(root.path, privacy: .public)")
                continue
            }
            if bookmark(root) { continue }
            // A volume root (a memory card picked directly in the open
            // panel) cannot be bookmarked at all — creation fails with
            // "File descriptor doesn't match the bookmarked path", sandboxed
            // or not. Descendants of the grant bookmark fine, so fall back
            // to the covered frames' parent folders, which together still
            // cover every frame on resolution.
            for parent in Set(covered.map { $0.deletingLastPathComponent() })
            where parent.path != root.path {
                _ = bookmark(parent)
            }
        }
        return bookmarks.isEmpty ? nil : bookmarks
        #endif
    }

    private func stopScopedAccess() {
        #if os(macOS)
        for url in scopedAccessURLs { url.stopAccessingSecurityScopedResource() }
        #endif
        scopedAccessURLs = []
    }

    /// Resolves saved bookmarks and starts access. `remap` translates a moved
    /// or renamed root's stored path prefix to where the bookmark found it, so
    /// persisted frame paths keep working. Staleness needs no handling here:
    /// the next save re-creates bookmarks from the resolved roots.
    nonisolated private static func resolveScopedAccess(_ bookmarks: [String: Data]?)
        -> (roots: [URL], accessed: [URL], remap: [String: String]) {
        #if !os(macOS)
        // Plain paths resolve directly without grants off macOS.
        return ([], [], [:])
        #else
        guard let bookmarks else { return ([], [], [:]) }
        var roots = [URL](), accessed = [URL](), remap = [String: String]()
        for (path, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            roots.append(url)
            if url.path != path { remap[path] = url.path }
        }
        return (roots, accessed, remap)
        #endif
    }

    nonisolated private static func remappedURL(_ url: URL,
                                                remap: [String: String]) -> URL {
        guard !remap.isEmpty else { return url }
        let path = url.path
        for (old, new) in remap {
            if path == old { return URL(fileURLWithPath: new) }
            if path.hasPrefix(old + "/") {
                return URL(fileURLWithPath: new + path.dropFirst(old.count))
            }
        }
        return url
    }

    // MARK: - Stack selection

    /// Writes the selected-stack mirrors back into their Stack. The live
    /// retouch session is reduced to its working pixels (source caches are
    /// gigabytes; only the selected stack keeps a session).
    private func stash(into stack: Stack) {
        mergeRetouchDepth()
        stack.frames = frames
        stack.included = included
        stack.frameIssues = frameIssues
        stack.result = result
        stack.depthResult = depthResult
        stack.resultDepth = resultDepth
        stack.resultSharpness = resultSharpness
        stack.resultGains = resultGains
        stack.fuseURLs = fuseURLs
        stack.fusedSettings = fusedSettings
        stack.tone = tone
        stack.cropRect = cropRect
        stack.cropAngle = cropAngle
        stack.outputPreview = outputPreview
        stack.depthPreview = depthPreview
        if case .failed(let message) = phase {
            stack.failureMessage = message
        } else {
            stack.failureMessage = nil
        }
        if let session = retouch {
            stack.savedWorking = session.hasEdits ? session.working : savedWorking
            stack.savedSourceIndex = session.sourceIndex
        } else {
            stack.savedWorking = savedWorking
            stack.savedSourceIndex = savedSourceIndex
        }
        stack.undoHistory = undoHistory
        stack.redoHistory = redoHistory
    }

    /// Installs a Stack into the selected-stack mirrors, resetting everything
    /// transient (previews, caches, live retouch session, noise-floor data).
    private func install(from stack: Stack) {
        frames = stack.frames
        included = stack.included
        frameIssues = stack.frameIssues
        result = stack.result
        depthResult = stack.depthResult
        resultDepth = stack.resultDepth
        resultSharpness = stack.resultSharpness
        resultGains = stack.resultGains
        fuseURLs = stack.fuseURLs
        fusedSettings = stack.fusedSettings
        installingStack = true
        tone = stack.tone
        cropRect = stack.cropRect
        cropAngle = stack.cropAngle
        installingStack = false
        outputPreview = stack.outputPreview
        depthPreview = stack.depthPreview
        savedWorking = stack.savedWorking
        savedSourceIndex = stack.savedSourceIndex
        undoHistory = stack.undoHistory
        redoHistory = stack.redoHistory
        toneEditBaseline = nil
        retouch = nil
        retouchMode = false
        noiseFloorPreview = nil
        noiseFloorPreviewData = nil
        noiseFloorPreviewDataEpoch += 1  // invalidate any in-flight build
        noiseFloorPreviewActive = false
        progressive = nil
        inputCache = [:]
        inputCacheOrder = []
        inputPreview = nil
        inputPreviewURL = nil
        inputPreviewAligned = false
        inputPreviewError = nil
        inputPixelSize = nil
        viewport.reset()
        if stack.result != nil {
            phase = .done
        } else if let message = stack.failureMessage {
            phase = .failed(message)
        } else {
            phase = frames.isEmpty ? .empty : .loaded
        }
        if let first = frames.first {
            selection = [first]
            selectionChanged()
        } else {
            selection = []
        }
    }

    public func selectStack(_ id: UUID) {
        guard id != selectedStackID, !phase.isRunning,
              let target = stacks.first(where: { $0.id == id }) else { return }
        if let current = selectedStack { stash(into: current) }
        selectedStackID = id
        install(from: target)
    }

    /// Live status for the tree's glyphs: the selected stack reads the
    /// mirrors (its Stack object is stale until stashed).
    public func status(of stack: Stack) -> StackStatus {
        if stack.id == selectedStackID {
            if phase.isRunning { return .fusing }
            if result != nil { return .fused }
            if case .failed(let message) = phase { return .failed(message) }
            return .unfused
        }
        if stack.result != nil { return .fused }
        if let message = stack.failureMessage { return .failed(message) }
        return .unfused
    }

    public func setStackEnabled(_ id: UUID, to value: Bool) {
        guard let stack = stacks.first(where: { $0.id == id }) else { return }
        objectWillChange.send()
        stack.enabled = value
    }

    /// File > Close Stack: removes the selected stack from the project. Its
    /// fused result and retouch edits go with it (they can't be recomputed),
    /// so a fused stack asks first unless everything is already saved.
    public func closeSelectedStack() {
        guard !phase.isRunning, let stack = selectedStack else { return }
        stash(into: stack)
        if stack.result != nil, hasUnsavedWork,
           !runConfirmAlert(message: "Close the stack “\(stack.name)”?",
                            informative: "Any unsaved work in it will be lost.",
                            confirmTitle: "Close Stack") {
            return
        }
        let index = stacks.firstIndex { $0.id == stack.id } ?? 0
        stacks.removeAll { $0.id == stack.id }
        expandedStacks.remove(stack.id)
        guard let neighbor = stacks.indices.contains(index)
            ? stacks[index] : stacks.last else {
            clearProject()  // last stack closed = fresh state
            return
        }
        hasUnsavedWork = true  // the project's stack list changed
        selectedStackID = neighbor.id
        install(from: neighbor)
    }

    /// File > Close Project: back to the freshly launched empty state.
    public func closeProject() {
        guard !phase.isRunning else { return }
        guard confirmDiscardingUnsavedWork(message: "Close this project?",
                                           confirmTitle: "Close Project") else { return }
        clearProject()
    }

    private func clearProject() {
        resetForNewProject()
        stopScopedAccess()
        grantedRoots = []
        phase = .empty
    }

    /// Finder double-clicks and Dock drops of .hyperfocal files land here
    /// (application(_:open:) via the app delegate); window drops route here
    /// too. Same replace-the-project confirmation as File > Open Project.
    func openExternal(urls: [URL]) {
        guard !phase.isRunning,
              let project = urls.first(where: {
                  $0.pathExtension.lowercased() == ProjectStore.fileExtension
              }) else { return }
        guard confirmDiscardingUnsavedWork(message: "Open a different project?",
                                           confirmTitle: "Open Project") else { return }
        openProject(from: project)
    }

    public var fusedStackCount: Int {
        stacks.filter { $0.id == selectedStackID ? result != nil : $0.result != nil }.count
    }

    /// True when fusing this stack would produce something its current result
    /// isn't: no result yet, the included frame set changed, or a fusion
    /// parameter changed since (per the `FuseSettings` snapshot; projects
    /// saved before snapshots existed only track frame-set changes).
    func needsRefuse(_ stack: Stack) -> Bool {
        let isSelected = stack.id == selectedStackID
        let stackResult = isSelected ? result : stack.result
        guard stackResult != nil else { return true }
        let stackFrames = isSelected ? frames : stack.frames
        let stackIncluded = isSelected ? included : stack.included
        let stackFuseURLs = isSelected ? fuseURLs : stack.fuseURLs
        if stackFrames.filter({ stackIncluded.contains($0) }) != stackFuseURLs { return true }
        if let snapshot = isSelected ? fusedSettings : stack.fusedSettings,
           snapshot != currentFuseSettings() {
            return true  // a new fuse would produce a different result
        }
        return false
    }

    /// Stacks the queue button would fuse: enabled and out of date.
    public var pendingStackCount: Int {
        stacks.filter { $0.enabled && needsRefuse($0) }.count
    }

    private func currentFuseSettings() -> FuseSettings {
        FuseSettings(align: alignFrames,
                     useGPU: useGPU,
                     sharpnessSigma: sharpnessSigma,
                     noiseFloor: noiseFloor,
                     medianRadius: medianRadius,
                     blendRadius: blendRadius,
                     normalizeExposure: normalizeExposure)
    }

    // MARK: - Session persistence

    private func captureProject() -> ProjectStore.Project? {
        if let current = selectedStack { stash(into: current) }
        // Unfused stacks save fine (frame lists, inclusion, transforms) —
        // there's no reason to demand a fused result before allowing Save.
        guard !stacks.isEmpty else { return nil }
        let payloads = stacks.map { stack in
            ProjectStore.StackPayload(
                name: stack.name,
                enabled: stack.enabled,
                frameURLs: stack.frames,
                includedURLs: stack.included,
                transforms: alignmentCache.transforms(for: stack.fuseURLs),
                result: stack.result,
                depth: stack.resultDepth,
                sharpness: stack.resultSharpness,
                working: stack.savedWorking,
                sourceIndex: stack.savedSourceIndex,
                gains: stack.resultGains,
                orderWarning: stack.orderWarning,
                fusedSettings: stack.fusedSettings,
                tone: stack.tone.isNeutral ? nil : stack.tone,
                crop: stack.cropRect.map {
                    [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)]
                },
                cropAngle: stack.cropAngle == 0 ? nil : stack.cropAngle)
        }
        return ProjectStore.Project(
            stacks: payloads,
            selectedIndex: stacks.firstIndex { $0.id == selectedStackID },
            bookmarks: currentBookmarks())
    }

    /// Quit-time unsaved-work check (invoked by the app delegate before
    /// termination). Projects hold retouch edits that can't be recomputed, so
    /// losing one silently is unacceptable — but writing it automatically
    /// takes too long at 45 MP (hundreds of MB of blobs), so quitting asks.
    /// The quit gate's sibling for in-app actions that replace the current
    /// project: fused results and retouch edits can't be recomputed, so
    /// anything that discards them asks first. True means proceed.
    public func confirmDiscardingUnsavedWork(message: String, confirmTitle: String) -> Bool {
        guard hasUnsavedWork, fusedStackCount > 0, !phase.isRunning else { return true }
        return runConfirmAlert(message: message,
                               informative: "Any unsaved work will be lost.",
                               confirmTitle: confirmTitle)
    }

    /// Frontend-provided modal interactions (panels, alerts) — the Mac app
    /// wires MacDialogService at launch. Nil (probe, unwired tests) resolves
    /// every interaction as "cancelled"; the per-prompt test overrides below
    /// short-circuit before it either way.
    public var dialogs: DialogService?

    /// Change-notification seam for non-Combine clients (the C-ABI
    /// bridge): `observer` fires on the main thread for every model
    /// mutation, exactly like objectWillChange — values may not have
    /// landed yet, so clients coalesce and re-read on the next turn.
    /// Combine stays an implementation detail of AppCore behind this
    /// method; the Linux port swaps the mechanism here without touching
    /// clients. Release the returned token to stop observing.
    public func addChangeObserver(_ observer: @escaping () -> Void) -> AnyObject {
        objectWillChange.sink { _ in observer() }
    }

    /// Testability hook: when set, confirmation alerts are answered by the
    /// closure (keyed on the message) instead of blocking on a modal — the
    /// probe exercises close/replace flows headlessly through this.
    var confirmAlertOverride: ((String) -> Bool)?

    private func runConfirmAlert(message: String, informative: String,
                                 confirmTitle: String) -> Bool {
        if let confirmAlertOverride { return confirmAlertOverride(message) }
        return dialogs?.confirm(message: message, informative: informative,
                                confirmTitle: confirmTitle,
                                cancelTitle: "Cancel", warning: false) ?? false
    }

    /// Warns before fusing when the fusion disk cache is enabled but the
    /// temp volume can't hold it — the fuse still works without the cache,
    /// just slower, so the user picks between fusing anyway, making room,
    /// and turning the cache off in Settings. Batches never prompt (an
    /// unattended queue must keep moving; the engine skips the cache
    /// silently and the skip is logged). Returns false to cancel the fuse.
    private func preflightDiskCache(urls: [URL]) -> Bool {
        guard !batchMode, useGPU, FrameSpill.wanted(fusionDiskCache),
              let first = urls.first,
              let size = ImageFile.pixelSize(url: first),
              let short = FrameSpill.shortfall(frameBytes: size.width * size.height * 16,
                                               frameCount: urls.count) else { return true }
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return runConfirmAlert(
            message: "Not enough disk space for the fusion cache",
            informative: "Fusion normally uses a disk cache to improve performance. This stack "
                + " needs about \(fmt(short.needed)) and the disk has \(fmt(short.available)) "
                + "free. Fusion will be slower without a disk cache.",
            confirmTitle: "Fuse Anyway")
    }

    /// Quit-time confirm; true = terminate. Bool (not AppKit's
    /// TerminateReply) so AppCore stays toolkit-neutral — the app maps
    /// it at the delegate edge.
    func confirmTermination() -> Bool {
        guard hasUnsavedWork, fusedStackCount > 0, !phase.isRunning else { return true }
        return runConfirmAlert(message: "Are you sure you want to quit?",
                               informative: "Unsaved data will be lost.",
                               confirmTitle: "Quit")
    }

    /// File > Save: writes straight back to the project's file; a
    /// never-saved project falls through to Save As.
    func saveProject() {
        afterUpdate {
            guard let projectURL = $0.projectURL else { return $0.runSaveProjectPanel() }
            $0.writeProject(to: projectURL)
        }
    }

    /// File > Save As (and Save's first-save fallback).
    func saveProjectAs() {
        afterUpdate { $0.runSaveProjectPanel() }
    }

    private func runSaveProjectPanel() {
        guard captureProject() != nil else { return }
        // Saving-as from a saved project starts where the project lives.
        let directory = projectURL?.deletingLastPathComponent()
        let name = projectURL?.lastPathComponent
            ?? "\(stacks.first?.name ?? "Project").\(ProjectStore.fileExtension)"
        guard let url = dialogs?.chooseSaveProject(directory: directory,
                                                   suggestedName: name) else { return }
        writeProject(to: url)
    }

    /// Panel-free save: the write body of saveProject/saveProjectAs,
    /// callable directly (UITestSupport, and any future probe checks).
    @discardableResult
    public func writeProject(to url: URL) -> Bool {
        guard let project = captureProject() else { return false }
        do {
            try ProjectStore.write(project, to: url)
            hasUnsavedWork = false
            projectURL = url  // a successful write makes this THE document
            return true
        } catch {
            // A failed save must not touch `phase`: the fused result is
            // still valid, and .failed would disable Save itself (plus
            // export and retouch) until a pointless re-fuse. Report and
            // leave the session exactly as it was.
            dialogs?.notify(message: "Couldn't save the project",
                            informative: error.localizedDescription, warning: true)
            return false
        }
    }

    func openProjectPanel() {
        afterUpdate { $0.runOpenProjectPanel() }
    }

    private func runOpenProjectPanel() {
        guard confirmDiscardingUnsavedWork(message: "Open a different project?",
                                           confirmTitle: "Open Project") else { return }
        guard let url = dialogs?.chooseProjectToOpen() else { return }
        openProject(from: url)
    }

    private struct RestoredStack {
        let payload: ProjectStore.StackPayload
        let outputCG: PlatformImage?
        let depthCG: PlatformImage?
        let depthImage: ImageBuffer?
    }

    func openProject(from url: URL) {
        guard !phase.isRunning else { return }
        phase = .running
        stageText = "Restoring project…"
        stageFraction = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let project = try ProjectStore.read(from: url)
                var restored = [RestoredStack]()
                for payload in project.stacks {
                    var outputCG: PlatformImage? = nil
                    var depthCG: PlatformImage? = nil
                    var depthImage: ImageBuffer? = nil
                    if let result = payload.result {
                        outputCG = try Preview.image(from: payload.working ?? result)
                        let image = DMapFusion.depthImage(
                            from: payload.depth, width: result.width, height: result.height,
                            frameCount: max(payload.includedURLs.count, 2))
                        depthImage = image
                        depthCG = try Preview.image(from: image)
                    }
                    restored.append(RestoredStack(payload: payload, outputCG: outputCG,
                                                  depthCG: depthCG, depthImage: depthImage))
                }
                // Resolve last, after everything that can throw, so a failed
                // restore never leaves dangling startAccessing calls.
                let access = Self.resolveScopedAccess(project.bookmarks)
                let items = restored
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.installRestored(items, selectedIndex: project.selectedIndex,
                                         access: access)
                    self.projectURL = url  // only on success: a failed open
                                           // leaves the prior project (and
                                           // its URL) in place
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.phase = .failed("project restore failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func installRestored(_ restored: [RestoredStack], selectedIndex: Int?,
                                 access: (roots: [URL], accessed: [URL], remap: [String: String])) {
        projectGeneration += 1  // fresh context — sidebar scroll resets
        stopScopedAccess()
        scopedAccessURLs = access.accessed
        var newStacks = [Stack]()
        for item in restored {
            let stackFrames = item.payload.frameURLs.map { Self.remappedURL($0, remap: access.remap) }
            let stack = Stack(name: item.payload.name, frames: stackFrames)
            stack.enabled = item.payload.enabled
            stack.included = Set(item.payload.includedURLs.map { Self.remappedURL($0, remap: access.remap) })
                .intersection(stackFrames)
            stack.fuseURLs = stack.frames.filter { stack.included.contains($0) }
            if let transforms = item.payload.transforms,
               transforms.count == stack.fuseURLs.count {
                alignmentCache.store(transforms, for: stack.fuseURLs)
            }
            stack.result = item.payload.result
            stack.resultDepth = item.payload.depth
            stack.resultSharpness = item.payload.sharpness
            stack.resultGains = item.payload.gains
            stack.orderWarning = item.payload.orderWarning
            stack.fusedSettings = item.payload.fusedSettings
            stack.tone = item.payload.tone ?? ToneSettings()
            stack.cropRect = item.payload.crop.flatMap {
                $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil
            }
            stack.cropAngle = item.payload.cropAngle ?? 0
            stack.depthResult = item.depthImage
            stack.savedWorking = item.payload.working
            stack.savedSourceIndex = item.payload.sourceIndex
            stack.outputPreview = item.outputCG
            stack.depthPreview = item.depthCG
            newStacks.append(stack)
        }
        // Bookmark-resolved roots become this session's grants, so re-saving
        // writes fresh bookmarks. Projects saved before bookmarks existed (or
        // opened non-sandboxed) fall back to the frames' parent folders —
        // bookmark creation on save succeeds wherever we truly have access.
        grantedRoots = access.roots.isEmpty
            ? Array(Set(newStacks.flatMap(\.frames).map { $0.deletingLastPathComponent() }))
            : access.roots
        stacks = newStacks
        expandedStacks = Set(newStacks.map(\.id))
        hasUnsavedWork = false  // exactly what the opened file holds
        let index = selectedIndex.flatMap { newStacks.indices.contains($0) ? $0 : nil } ?? 0
        if newStacks.indices.contains(index) {
            selectedStackID = newStacks[index].id
            install(from: newStacks[index])
        } else {
            selectedStackID = nil
            phase = .empty
        }
        // The sandbox may still be unable to read the frames — a project
        // saved while bookmark creation was broken (e.g. the app bundle was
        // rebuilt under a running instance) carries none, and stale ones can
        // fail to resolve. Detect by actually trying to read, and offer to
        // re-grant now — at save time there was nothing the user could do,
        // but here a folder pick fixes the project for good.
        let denied = deniedFrameRoots()
        if !denied.isEmpty {
            Self.bookmarkLog.error(
                "restore: \(denied.count) folder(s) unreadable, offering re-grant")
            afterUpdate { $0.offerAccessRegrant(for: denied) }
        }
    }

    /// Parent folders of restored frames the sandbox refuses to read
    /// (permission errors only — a *missing* file is a different problem
    /// with its own diagnostics, and a re-grant wouldn't help it). One
    /// probe read per folder; unsandboxed builds and already-granted
    /// sessions read fine and return nothing.
    private func deniedFrameRoots() -> [URL] {
        var checked = Set<URL>()
        var denied = [URL]()
        for frame in stacks.flatMap(\.frames) {
            let parent = frame.deletingLastPathComponent()
            guard checked.insert(parent).inserted else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: frame)
                try? handle.close()
            } catch {
                let ns = error as NSError
                let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
                    .flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
                if ns.code == CocoaError.fileReadNoPermission.rawValue
                    || posix == Int(EPERM) || posix == Int(EACCES) {
                    denied.append(parent)
                }
            }
        }
        return denied
    }

    /// Testability hooks: the re-grant alert (argument: folder count; true =
    /// "Grant Access…") and the folder picker (returns the "picked" folder
    /// for a requested root, nil = cancel) — panels can't run headless.
    var accessPromptOverride: ((Int) -> Bool)?
    var accessGrantPicker: ((URL) -> URL?)?

    private func offerAccessRegrant(for roots: [URL]) {
        let folders = roots.count == 1
            ? "the folder “\(roots[0].lastPathComponent)”"
            : "\(roots.count) folders"
        let proceed: Bool
        if let accessPromptOverride {
            proceed = accessPromptOverride(roots.count)
        } else {
            proceed = dialogs?.confirm(
                message: "Hyperfocal doesn’t have permission to read this project’s images",
                informative: "macOS grants access folder by folder, and the permission "
                    + "this project saved couldn’t be restored. Grant access to \(folders) to load "
                    + "the images — saving the project afterward keeps the access for next time. "
                    + "Fused results are intact either way.",
                confirmTitle: "Grant Access…", cancelTitle: "Not Now",
                warning: true) ?? false
        }
        guard proceed else { return }
        regrantAccess(to: roots)
    }

    private func regrantAccess(to roots: [URL]) {
        var newGrants = [URL]()
        func coveredByNewGrant(_ root: URL) -> Bool {
            newGrants.contains {
                root.path == $0.path || root.path.hasPrefix($0.path + "/")
            }
        }
        for root in roots where !coveredByNewGrant(root) {
            while true {
                let picked: URL?
                if let accessGrantPicker {
                    picked = accessGrantPicker(root)
                } else {
                    picked = dialogs?.chooseAccessGrant(for: root)
                }
                guard let picked else { break }  // cancelled: skip this folder
                // The pick helps only if it covers the folder the frames
                // live in (the folder itself or any ancestor).
                if root.path == picked.path || root.path.hasPrefix(picked.path + "/") {
                    grantedRoots.append(picked)
                    newGrants.append(picked)
                    Self.bookmarkLog.notice(
                        "re-granted \(picked.path, privacy: .public) for \(root.path, privacy: .public)")
                    break
                }
                // A real panel gets a correction + retry; a test hook would
                // just return the same answer forever.
                guard accessGrantPicker == nil else { break }
                guard dialogs?.confirm(
                    message: "That folder doesn’t contain the project’s images",
                    informative: "The images are in “\(root.path)”. Choose that folder, "
                        + "or any folder that contains it.",
                    confirmTitle: "Try Again", cancelTitle: "Skip",
                    warning: true) == true else { break }
            }
        }
        guard !newGrants.isEmpty else { return }
        // Fresh bookmarks exist only in a re-saved project file.
        hasUnsavedWork = true
        // The input pane may have already tried (and failed) to decode.
        inputCache = [:]
        inputCacheOrder = []
        if let url = inputPreviewURL ?? selection.first {
            inputPreviewURL = nil
            showInputFrame(url)
        }
    }

    /// Lock-protected counter readable from any thread — the noise-floor
    /// preview's compute tasks poll it mid-fit to abort stale work.
    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        func current() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public private(set) var result: ImageBuffer?
    private(set) var depthResult: ImageBuffer?
    private var inputCache: [URL: (image: PlatformImage, pixelSize: CGSize, aligned: Bool)] = [:]
    private var inputCacheOrder: [URL] = []
    private var inputDecodeTask: Task<Void, Never>?

    nonisolated static let stackableExtensions: Set<String> =
        ImageFile.rawExtensions.union(["tif", "tiff", "png", "jpg", "jpeg"])

    var includedFrames: [URL] { frames.filter { included.contains($0) } }
    // The engine's shipped defaults for the sidebar's fusion sliders —
    // what the Reset button restores (mirrors DMapFusion.Options defaults).
    static let defaultSharpnessSigma = 10.0
    static let defaultNoiseFloor = 0.05
    static let defaultMedianRadius = 20.0
    static let defaultBlendRadius = 1.0

    public var fusionSettingsAreDefault: Bool {
        sharpnessSigma == Self.defaultSharpnessSigma
            && noiseFloor == Self.defaultNoiseFloor
            && medianRadius == Self.defaultMedianRadius
            && blendRadius == Self.defaultBlendRadius
    }

    public func resetFusionSettings() {
        sharpnessSigma = Self.defaultSharpnessSigma
        noiseFloor = Self.defaultNoiseFloor
        medianRadius = Self.defaultMedianRadius
        blendRadius = Self.defaultBlendRadius
    }

    public var canFuse: Bool {
        includedFrames.count >= 2 && !phase.isRunning
            && (selectedStack?.enabled ?? true)
            && (selectedStack.map { needsRefuse($0) } ?? true)
    }
    var canExport: Bool { result != nil && !phase.isRunning }

    /// Crop-rectangle editing mode: the panes show the full canvas with the
    /// CropOverlay on the output pane; everywhere else they show only the
    /// crop.
    @Published public var cropMode = false

    public var canCrop: Bool { result != nil && phase == .done && !retouchMode }

    /// Fixed aspect-ratio constraint while editing the crop.
    public enum CropAspect: String, CaseIterable {
        case original = "Original"
        case custom = "Custom"
        case square = "1:1"
        case threeTwo = "3:2"
        case fiveFour = "5:4"
        case fourThree = "4:3"
        case sixteenNine = "16:9"
        /// width/height in landscape orientation; nil = unconstrained.
        func baseRatio(canvas: CGSize) -> CGFloat? {
            switch self {
            case .original:
                return canvas.height > 0 ? max(canvas.width / canvas.height,
                                               canvas.height / canvas.width) : nil
            case .custom: return nil
            case .square: return 1
            case .threeTwo: return 3 / 2
            case .fiveFour: return 5 / 4
            case .fourThree: return 4 / 3
            case .sixteenNine: return 16 / 9
            }
        }
    }
    @Published public var cropAspect: CropAspect = .custom {
        didSet { reshapeCropToAspect() }
    }
    /// Portrait orientation for the locked aspect (the X key toggles).
    @Published public var cropPortrait = false {
        didSet { reshapeCropToAspect() }
    }
    /// The active width/height constraint, orientation applied.
    public var cropAspectRatio: CGFloat? {
        guard let result else { return nil }
        guard let base = cropAspect.baseRatio(
                canvas: CGSize(width: result.width, height: result.height)),
              base != 1 || !cropPortrait else { return cropAspect == .square ? 1 : nil }
        return cropPortrait ? 1 / base : base
    }

    /// The rotation the panes should apply alongside displayCrop.
    public var displayCropAngle: Double { displayCrop != nil ? cropAngle : 0 }

    /// X key / the orientation button: swap the crop between landscape and
    /// portrait. Locked aspects flip via cropPortrait (whose didSet
    /// reshapes); Custom transposes the rect's own dimensions about its
    /// center. Either way the result is shrunk/recentered to fit.
    public func toggleCropOrientation() {
        guard cropMode else { return }
        cropPortrait.toggle()
        if cropAspectRatio == nil, let r = cropRect {
            let c = CGPoint(x: r.midX, y: r.midY)
            cropRect = fittedToCanvas(CGRect(x: c.x - r.height / 2,
                                             y: c.y - r.width / 2,
                                             width: r.height, height: r.width))
        }
    }

    /// Shrinks (about center) and recenters a candidate crop until its
    /// four corners — rotated by cropAngle — fit inside the canvas.
    private func fittedToCanvas(_ r: CGRect) -> CGRect {
        guard let result else { return r }
        let canvasW = CGFloat(result.width), canvasH = CGFloat(result.height)
        let rad = CGFloat(cropAngle) * .pi / 180
        let cosA = abs(cos(rad)), sinA = abs(sin(rad))
        var w = r.width, h = r.height
        // Rotated bounding half-extents must fit in half the canvas.
        let scale = min(1, canvasW / (w * cosA + h * sinA),
                        canvasH / (w * sinA + h * cosA))
        w *= scale
        h *= scale
        let hw = (w * cosA + h * sinA) / 2
        let hh = (w * sinA + h * cosA) / 2
        let cx = min(max(r.midX, hw), canvasW - hw)
        let cy = min(max(r.midY, hh), canvasH - hh)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).integral
    }

    /// Re-shapes the current rect to the locked ratio about its center,
    /// preserving area, clamped to the canvas.
    private func reshapeCropToAspect() {
        guard cropMode, result != nil, let r = cropRect,
              let ratio = cropAspectRatio else { return }
        // Preserve area at the new ratio, then shrink/recenter to fit
        // (including under the current rotation).
        let area = r.width * r.height
        let w = sqrt(area * ratio)
        cropRect = fittedToCanvas(CGRect(x: r.midX - w / 2,
                                         y: r.midY - w / ratio / 2,
                                         width: w, height: w / ratio))
    }

    /// The crop the panes should render right now: nil while editing (the
    /// whole canvas must be visible to drag handles on) or when no valid
    /// crop is set. Bounds-checked against the current result so a stale
    /// rect from a re-fused canvas can't shear the display. Retouch shows
    /// it too — strokes still land in full-image coordinates; only the
    /// presentation is cropped.
    public var displayCrop: CGRect? {
        guard !cropMode, !phase.isRunning, let result else { return nil }
        return Self.validCrop(cropRect, width: result.width, height: result.height)
    }

    // MARK: - Undo history (non-stroke edits)

    /// A reversible model edit. Value snapshots, not closures: applying one
    /// writes the stored values through the same paths the UI uses, and a
    /// snapshot can't dangle — histories are per stack, stashed and
    /// installed with everything else (and, like retouch stroke undo, they
    /// live for the session only; project files don't carry them).
    enum ModelEdit {
        case tone(from: ToneSettings, to: ToneSettings)
        case crop(fromRect: CGRect?, fromAngle: Double,
                  toRect: CGRect?, toAngle: Double)
        case included(from: Set<URL>, to: Set<URL>)

        var noun: String {
            switch self {
            case .tone: return "Tone Adjustment"
            case .crop: return "Crop"
            case .included: return "Frame Selection"
            }
        }
    }
    @Published private(set) var undoHistory: [ModelEdit] = []
    @Published private(set) var redoHistory: [ModelEdit] = []
    static let maxUndoEdits = 50

    /// ⌘Z is mode-scoped: inside retouch it drives stroke undo (as ever);
    /// everywhere else it walks the model-edit history. Crop mode has its
    /// own transaction (⎋ cancels), so history stays out of its way.
    public var canUndoEdit: Bool { retouchMode ? retouch != nil : !cropMode && !undoHistory.isEmpty }
    public var canRedoEdit: Bool { retouchMode ? retouch != nil : !cropMode && !redoHistory.isEmpty }
    public var undoMenuTitle: String {
        retouchMode ? "Undo Stroke" : undoHistory.last.map { "Undo \($0.noun)" } ?? "Undo"
    }
    public var redoMenuTitle: String {
        retouchMode ? "Redo Stroke" : redoHistory.last.map { "Redo \($0.noun)" } ?? "Redo"
    }

    public func undoEdit() {
        if retouchMode { retouch?.undo(); return }
        guard !cropMode, let edit = undoHistory.popLast() else { return }
        redoHistory.append(edit)
        apply(edit, forward: false)
    }

    public func redoEdit() {
        if retouchMode { retouch?.redo(); return }
        guard !cropMode, let edit = redoHistory.popLast() else { return }
        undoHistory.append(edit)
        apply(edit, forward: true)
    }

    private func recordEdit(_ edit: ModelEdit) {
        undoHistory.append(edit)
        if undoHistory.count > Self.maxUndoEdits { undoHistory.removeFirst() }
        redoHistory = []
    }

    private func apply(_ edit: ModelEdit, forward: Bool) {
        switch edit {
        case .tone(let from, let to):
            tone = forward ? to : from
        case .crop(let fromRect, let fromAngle, let toRect, let toAngle):
            cropRect = forward ? toRect : fromRect
            cropAngle = forward ? toAngle : fromAngle
            viewport.reset()  // the panes refit to the (un)cropped canvas
        case .included(let from, let to):
            included = forward ? to : from
        }
    }

    /// Tone slider gesture hooks (LabeledSlider's onEditingChanged): one
    /// undo step per drag, however many ticks it delivered.
    private var toneEditBaseline: ToneSettings?
    public func toneEditing(_ editing: Bool) {
        if editing {
            toneEditBaseline = toneEditBaseline ?? tone
        } else if let from = toneEditBaseline {
            toneEditBaseline = nil
            if from != tone { recordEdit(.tone(from: from, to: tone)) }
        }
    }

    /// The Tone section's Reset button — an edit like any drag.
    public func resetTone() {
        guard !tone.isNeutral else { return }
        recordEdit(.tone(from: tone, to: ToneSettings()))
        tone = ToneSettings()
    }

    /// Pre-edit state, restored by Cancel — crop editing is transactional.
    private var cropBackup: CGRect?
    private var cropAngleBackup: Double = 0

    public func beginCrop() {
        guard canCrop, !cropMode else { return }
        cropBackup = cropRect
        cropAngleBackup = cropAngle
        if cropRect == nil, let result {
            // Fresh crops start at the full canvas (accepting it untouched
            // still means "no crop").
            cropRect = CGRect(x: 0, y: 0, width: result.width, height: result.height)
        }
        cropMode = true
        reshapeCropToAspect()
        viewport.reset()  // fit the full canvas the handles live on
    }

    public func acceptCrop() {
        guard cropMode else { return }
        // Dragging the rect out to the whole canvas means "no crop".
        if cropAngle == 0, let result,
           let r = Self.validCrop(cropRect, width: result.width,
                                  height: result.height),
           r == CGRect(x: 0, y: 0, width: result.width, height: result.height) {
            cropRect = nil
        }
        cropMode = false
        if cropBackup != cropRect || cropAngleBackup != cropAngle {
            recordEdit(.crop(fromRect: cropBackup, fromAngle: cropAngleBackup,
                             toRect: cropRect, toAngle: cropAngle))
        }
        viewport.reset()
    }

    public func cancelCrop() {
        guard cropMode else { return }
        cropRect = cropBackup
        cropAngle = cropAngleBackup
        cropMode = false
        viewport.reset()
    }

    /// The image size the synced preview panes are currently showing —
    /// what menu-driven zoom should anchor to.
    var displayedImageSize: CGSize {
        if let crop = displayCrop { return crop.size }
        return retouch?.nominalSize ?? outputNominalSize ?? inputNominalSize
            ?? CGSize(width: 1, height: 1)
    }

    func zoomIn() { viewport.zoom(by: 1.5, imageSize: displayedImageSize) }
    func zoomOut() { viewport.zoom(by: 1 / 1.5, imageSize: displayedImageSize) }

    // MARK: - Frame intake

    /// Presents modal UI on the next main-queue turn — OUTSIDE the SwiftUI
    /// update that dispatched the calling button/menu action. A modal loop
    /// (panel/alert runModal) entered mid-update leaves that update's
    /// transaction open, and the window re-commits every frame for as long
    /// as the modal sits there — an idle Save dialog burned ~30% CPU.
    private func afterUpdate(_ body: @escaping @MainActor (AppModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    func openFrames() {
        afterUpdate { $0.runOpenFramesPanel() }
    }

    private func runOpenFramesPanel() {
        guard confirmDiscardingUnsavedWork(message: "Start a new project?",
                                           confirmTitle: "New Project") else { return }
        let urls = dialogs?.chooseFrames(message: "Choose a stack: a folder of frames, or the frames themselves (focus order = name order).") ?? []
        guard !urls.isEmpty else { return }
        ingest(urls: urls)
    }

    func addStackFolderPanel() {
        afterUpdate { $0.runAddStackFolderPanel() }
    }

    private func runAddStackFolderPanel() {
        guard !phase.isRunning else { return }
        let urls = dialogs?.chooseStackFolders(message: "Add stack folders to the project — each folder of frames becomes its own stack.") ?? []
        guard !urls.isEmpty else { return }
        loadStacks(from: urls, replacing: false)
    }

    public func ingest(urls: [URL]) {
        loadStacks(from: urls, replacing: true)
    }

    /// Drag-and-drop lands here: drops *add* stacks (like Add Stack Folder…)
    /// rather than replacing the project, so they never discard work and
    /// never need to warn. A dropped project file is the exception — that
    /// means "open this project", which replaces and therefore confirms.
    public func addStacks(urls: [URL]) {
        guard !phase.isRunning else { return }
        if urls.contains(where: {
            $0.pathExtension.lowercased() == ProjectStore.fileExtension
        }) {
            openExternal(urls: urls)
            return
        }
        loadStacks(from: urls, replacing: false)
    }

    /// Loading pipeline: scan off-main (directory recursion + EXIF capture
    /// times over possibly hundreds of files), then assemble stacks on main,
    /// asking the burst-split question at most once per load.
    private func loadStacks(from urls: [URL], replacing: Bool) {
        guard !phase.isRunning else { return }
        // The panel/drop URLs are exactly what the sandbox granted — folders
        // when folders were chosen, else the individual files.
        if replacing {
            stopScopedAccess()
            grantedRoots = urls
        } else {
            grantedRoots += urls
        }
        phase = .running
        stageText = "Scanning frames…"
        stageFraction = 0
        let orderByCaptureTime = orderByCaptureTime
        Task.detached(priority: .userInitiated) { [weak self] in
            let groups = Self.scanGroups(urls: urls,
                                         orderByCaptureTime: orderByCaptureTime)
            await MainActor.run { [weak self] in
                self?.installScanned(groups, replacing: replacing)
            }
        }
    }

    /// Every directory (recursively) that directly contains images becomes a
    /// group; loose files form one group of their own. Each group also carries
    /// its capture-time burst split for the one-question-per-load dialog.
    /// `orderByCaptureTime` picks the frame order within each group/burst
    /// (capture time survives filename-counter rollover; name order when off
    /// or when any frame is undated).
    nonisolated private static func scanGroups(urls: [URL], orderByCaptureTime: Bool)
        -> [(name: String, frames: [URL], bursts: [[URL]], dates: [URL: Date])] {
        let fm = FileManager.default
        var groups = [(name: String, frames: [URL])]()
        var loose = [URL]()
        func collect(directory: URL) {
            let contents = ((try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let images = contents.filter {
                stackableExtensions.contains($0.pathExtension.lowercased())
            }
            if !images.isEmpty {
                groups.append((directory.lastPathComponent, images))
            }
            for child in contents
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collect(directory: child)
            }
        }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                collect(directory: url)
            } else if stackableExtensions.contains(url.pathExtension.lowercased()) {
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            let name = loose[0].deletingLastPathComponent().lastPathComponent
            groups.insert((name, loose.sorted { $0.lastPathComponent < $1.lastPathComponent }),
                          at: 0)
        }
        // One EXIF pass per group feeds the frame order, the burst split,
        // and the order sanity check (hundreds of header reads on a card
        // load — don't do it twice).
        return groups.map { group in
            let dates = group.frames.map(StackSplitter.captureDate(of:))
            var dated = [URL: Date]()
            for (url, date) in zip(group.frames, dates) {
                if let date { dated[url] = date }
            }
            return (group.name,
                    StackSplitter.ordered(urls: group.frames, dates: dates,
                                          byCaptureTime: orderByCaptureTime),
                    StackSplitter.split(urls: group.frames, dates: dates,
                                        gap: StackSplitter.defaultGap,
                                        orderByCaptureTime: orderByCaptureTime),
                    dated)
        }
    }

    /// Warning text for a stack whose fusion order deserves a second look —
    /// nil when the order is trustworthy. Shown as a badge on the stack row:
    /// a shuffled or interleaved load fuses to garbage silently, and an
    /// undated stack quietly falls back to filename order.
    nonisolated private static func orderWarning(frames: [URL], dates: [URL: Date],
                                                 byCaptureTime: Bool) -> String? {
        switch StackSplitter.orderIssue(urls: frames,
                                        dates: frames.map { dates[$0] },
                                        byCaptureTime: byCaptureTime) {
        case .mismatch:
            return "Capture order and filename order disagree. Frames fuse in"
                + " capture order — right for a rolled-over file counter, but if"
                + " this folder mixes frames from different stacks, split them"
                + " before fusing."
        case .undated:
            return "These frames carry no capture times, so they fuse in"
                + " filename order. Make sure filenames follow focus order."
        case nil:
            return nil
        }
    }

    private func installScanned(_ groups: [(name: String, frames: [URL],
                                            bursts: [[URL]], dates: [URL: Date])],
                                replacing: Bool) {
        var splitChoice: Bool? = nil  // asked at most once per load
        var newStacks = [Stack]()
        func makeStack(name: String, frames: [URL], dates: [URL: Date]) -> Stack {
            let stack = Stack(name: name, frames: frames)
            stack.orderWarning = Self.orderWarning(frames: frames, dates: dates,
                                                   byCaptureTime: orderByCaptureTime)
            return stack
        }
        for group in groups {
            if group.bursts.filter({ $0.count >= 2 }).count >= 2 {
                if splitChoice == nil {
                    splitChoice = askSplitChoice(name: group.name,
                                                 burstCount: group.bursts.count)
                }
                if splitChoice == true {
                    for (i, burst) in group.bursts.enumerated() {
                        newStacks.append(makeStack(name: "\(group.name) \(i + 1)",
                                                   frames: burst, dates: group.dates))
                    }
                    continue
                }
            }
            newStacks.append(makeStack(name: group.name, frames: group.frames,
                                       dates: group.dates))
        }
        if replacing {
            resetForNewProject()
            stacks = newStacks
        } else {
            if let current = selectedStack { stash(into: current) }
            stacks += newStacks
        }
        disambiguateStackNames()
        expandedStacks.formUnion(newStacks.map(\.id))
        if replacing || selectedStackID == nil {
            if let first = stacks.first {
                selectedStackID = first.id
                install(from: first)
            } else {
                selectedStackID = nil
                phase = .empty
            }
        } else if let added = newStacks.first {
            // Appending: jump to the first added stack so it's visible.
            selectedStackID = added.id
            install(from: added)
        } else if let current = selectedStack {
            install(from: current)  // nothing added; restore the phase
        }
    }

    private func askSplitChoice(name: String, burstCount: Int) -> Bool {
        if let splitChoicePrompt { return splitChoicePrompt(name, burstCount) }
        return dialogs?.confirm(
            message: "“\(name)” looks like \(burstCount) separate stacks",
            informative: "Capture times show \(burstCount) bursts separated by more than \(Int(StackSplitter.defaultGap)) seconds. Load them as separate stacks, or keep each folder as one stack?\n\nThis choice applies to every folder in this load.",
            confirmTitle: "Separate Stacks", cancelTitle: "One Stack per Folder",
            warning: false) ?? false
    }

    /// Two folders named "stack" in different parents would collide in the
    /// tree and in Export All filenames; number the later ones.
    private func disambiguateStackNames() {
        var seen = [String: Int]()
        for stack in stacks {
            let count = (seen[stack.name] ?? 0) + 1
            seen[stack.name] = count
            if count > 1 { stack.name = "\(stack.name) (\(count))" }
        }
    }

    /// Bumped whenever the whole project context is replaced (new project,
    /// close, open). The sidebar keys its settings form off this so scroll
    /// position resets to the top instead of surviving into an unrelated
    /// project.
    @Published private(set) var projectGeneration = 0

    private func resetForNewProject() {
        projectGeneration += 1
        // Cached alignments must die with the project: a re-opened stack
        // should register fresh, not silently reuse transforms from a
        // previous session's load. (Project restore re-seeds the cache from
        // the stored transforms after this runs.)
        alignmentCache.removeAll()
        resetFusionSettings()
        stacks = []
        selectedStackID = nil
        expandedStacks = []
        cropRect = nil  // BEFORE the unsaved flag clears: its didSet marks unsaved
        cropAngle = 0
        hasUnsavedWork = false
        projectURL = nil  // the next Save must ask where to put it
        frames = []
        included = []
        selection = []
        frameIssues = [:]
        result = nil
        depthResult = nil
        resultDepth = []
        resultSharpness = nil
        resultGains = nil
        fuseURLs = []
        fusedSettings = nil
        installingStack = true
        tone = ToneSettings()
        installingStack = false
        outputPreview = nil
        depthPreview = nil
        progressive = nil
        retouch = nil
        retouchMode = false
        savedWorking = nil
        savedSourceIndex = nil
        undoHistory = []
        redoHistory = []
        toneEditBaseline = nil
        noiseFloorPreview = nil
        noiseFloorPreviewData = nil
        noiseFloorPreviewDataEpoch += 1  // invalidate any in-flight build
        noiseFloorPreviewActive = false
        inputPreview = nil
        inputPreviewURL = nil
        inputPreviewAligned = false
        inputPreviewError = nil
        inputPixelSize = nil
        inputCache = [:]
        inputCacheOrder = []
        viewport.reset()
    }

    // MARK: - Fuse queue

    /// Fuses every enabled stack that doesn't have a result yet, serially
    /// (memory is bounded per fuse and one fuse already saturates the GPU —
    /// parallel stacks don't pay). Re-fusing one stack is what Fuse Stack is
    /// for. Bad frames are excluded silently — an unattended queue must keep
    /// moving. Cancel stops the whole queue.
    public func fuseEnabledStacks() {
        guard !phase.isRunning else { return }
        if let current = selectedStack { stash(into: current) }
        let pending = stacks.filter { $0.enabled && needsRefuse($0) }
        guard !pending.isEmpty else { return }
        batchMode = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures = [String]()
            for (i, stack) in pending.enumerated() {
                self.batchStatus = "Stack \(i + 1) of \(pending.count) · "
                self.selectStack(stack.id)
                guard self.canFuse else {
                    failures.append("\(stack.name): fewer than 2 included frames")
                    continue
                }
                self.fuse()
                while self.phase.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if case .failed(let message) = self.phase {
                    failures.append("\(stack.name): \(message)")
                } else if self.phase != .done {
                    failures.append("Cancelled at \(stack.name).")
                    break
                }
            }
            self.batchStatus = nil
            self.batchMode = false
            if !failures.isEmpty {
                let summary = failures.joined(separator: "\n")
                if let presenter = self.queueSummaryPresenter {
                    presenter(summary)
                } else {
                    self.dialogs?.notify(message: "Some stacks didn't fuse",
                                         informative: summary, warning: false)
                }
            }
        }
    }

    // MARK: - Export all

    func exportAllFusedPanel() {
        afterUpdate { $0.runExportAllPanel() }
    }

    private func runExportAllPanel() {
        guard fusedStackCount > 0, !phase.isRunning else { return }
        guard let dir = dialogs?.chooseExportDirectory(
            message: "Every fused stack is written to this folder.") else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summary = await self.exportAllFused(to: dir)
            if let presenter = self.queueSummaryPresenter {
                presenter(summary)
            } else {
                self.dialogs?.notify(message: "Export finished",
                                     informative: summary, warning: false)
            }
        }
    }

    /// Writes every fused stack (retouch edits included) to `directory` in the
    /// current export format and color space. Returns a summary line per stack.
    public func exportAllFused(to directory: URL) async -> String {
        if let current = selectedStack { stash(into: current) }
        let ext = exportFormat.fileExtension
        let space = exportColorSpace
        var lines = [String]()
        var count = 0
        for stack in stacks {
            guard let uncropped = stack.savedWorking ?? stack.result else { continue }
            let image = Self.cropped(uncropped, to: stack.cropRect,
                                     angle: stack.cropAngle)
            let dest = directory.appendingPathComponent("\(stack.name).\(ext)")
            let sourceFrame = stack.fuseURLs.first
            let tone = exportFormat == .dng ? ToneSettings() : stack.tone
            do {
                let stackTone = stack.tone
                let wantsSidecar = exportFormat == .dng && !stackTone.isNeutral
                try await Task.detached(priority: .userInitiated) {
                    var toned = image
                    ToneCurve.apply(settings: tone, to: &toned)
                    try Self.saveImage(toned, to: dest, sourceFrame: sourceFrame,
                                       colorSpace: space)
                    if wantsSidecar {
                        try XMPSidecar.embed(tone: stackTone, inDNGAt: dest)
                    }
                }.value
                count += 1
                lines.append("\(dest.lastPathComponent) ✓")
            } catch {
                lines.append("\(stack.name): \(error.localizedDescription)")
            }
        }
        return "\(count) stack\(count == 1 ? "" : "s") exported to “\(directory.lastPathComponent)”.\n\n"
            + lines.joined(separator: "\n")
    }

    /// Export Aligned Frames is offered when the selected stack has
    /// alignment transforms (fusing with alignment computes them) and at
    /// least one selected frame is part of the fused list. Without
    /// transforms the "aligned" frames would just be copies of the
    /// originals — pointless.
    public var canExportAligned: Bool {
        !phase.isRunning && alignmentCache.transforms(for: fuseURLs) != nil
            && selection.contains { fuseURLs.contains($0) }
    }

    func exportAlignedFramesPanel() {
        afterUpdate { $0.runExportAlignedPanel() }
    }

    private func runExportAlignedPanel() {
        guard canExportAligned else { return }
        guard let dir = dialogs?.chooseExportDirectory(
            message: "The selected frames are written to this folder, aligned to the fused canvas.") else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summary = await self.exportAlignedFrames(to: dir)
            if let presenter = self.queueSummaryPresenter {
                presenter(summary)
            } else {
                self.dialogs?.notify(message: "Export finished",
                                     informative: summary, warning: false)
            }
        }
    }

    /// Writes every selected frame of the fused list to `directory` as the
    /// fusion saw it — decoded and warped into the fused canvas (same
    /// common-coverage crop as the result), so the exports layer-stack
    /// pixel-perfectly under the exported result in an external editor.
    /// Format, color space, and tone follow the result-export rules (tone
    /// bakes into display-referred formats; DNG stays linear and carries
    /// tone as XMP). Returns a summary line per frame.
    public func exportAlignedFrames(to directory: URL) async -> String {
        let alignedURLs = fuseURLs
        guard let transforms = alignmentCache.transforms(for: alignedURLs) else {
            return "No alignment yet — fuse the stack (with alignment on) first."
        }
        let targets = frames.filter { selection.contains($0) && alignedURLs.contains($0) }
        let ext = exportFormat.fileExtension
        let space = exportColorSpace
        let bakedTone = exportFormat == .dng ? ToneSettings() : tone
        let wantsSidecar = exportFormat == .dng && !tone.isNeutral
        let sidecarTone = tone
        let source = StackPipeline.makeSource(urls: alignedURLs, transforms: transforms)
        var lines = [String]()
        var count = 0
        for url in targets {
            guard let index = alignedURLs.firstIndex(of: url) else { continue }
            let dest = directory.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent) aligned.\(ext)")
            do {
                let crop = cropRect
                let angle = cropAngle
                try await Task.detached(priority: .userInitiated) {
                    var image = Self.cropped(try source.frame(at: index), to: crop,
                                             angle: angle)
                    ToneCurve.apply(settings: bakedTone, to: &image)
                    try Self.saveImage(image, to: dest, sourceFrame: url,
                                       colorSpace: space)
                    if wantsSidecar {
                        try XMPSidecar.embed(tone: sidecarTone, inDNGAt: dest)
                    }
                }.value
                count += 1
                lines.append("\(dest.lastPathComponent) ✓")
            } catch {
                lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return "\(count) aligned frame\(count == 1 ? "" : "s") exported to “\(directory.lastPathComponent)”.\n\n"
            + lines.joined(separator: "\n")
    }

    /// Rocking animation needs a fused result AND its depth plane (DMap
    /// fills it; a project restored without depth can't animate).
    public var canAnimate: Bool {
        !phase.isRunning && result != nil && !resultDepth.isEmpty
    }

    func exportAnimation() {
        afterUpdate { $0.runAnimatePanel() }
    }

    private func runAnimatePanel() {
        guard canAnimate else { return }
        let base = (fuseURLs.first ?? frames.first)?
            .deletingLastPathComponent().lastPathComponent ?? "stacked"
        guard let url = dialogs?.chooseSaveAnimation(
            suggestedName: "\(base) rocking.\(animationFormat.fileExtension)") else { return }
        Task { [weak self] in
            _ = await self?.writeAnimation(to: url)
        }
    }

    /// Panel-free animation export (also the UI-test command seam): tone
    /// bakes in like every display-referred export, retouch edits included.
    /// Renders off-main; returns whether the file was written.
    public func writeAnimation(to url: URL) async -> Bool {
        mergeRetouchDepth()  // animate what the user retouched, depth included
        let baseImage = retouch?.hasEdits == true ? retouch?.working : (savedWorking ?? result)
        guard let uncropped = baseImage, !resultDepth.isEmpty else { return false }
        let image = Self.cropped(uncropped, to: cropRect, angle: cropAngle)
        let depth = Self.croppedDepth(resultDepth, width: uncropped.width,
                                      height: uncropped.height, to: cropRect,
                                      angle: cropAngle)
        let toneSettings = tone
        let options = RockingAnimation.Options(duration: animationDuration.seconds,
                                               fps: animationFPS.value,
                                               amplitude: animationStrength.amplitude,
                                               path: animationPath.enginePath)
        do {
            try await Task.detached(priority: .userInitiated) {
                var toned = image
                ToneCurve.apply(settings: toneSettings, to: &toned)
                try RockingAnimation.write(to: url, image: toned, depth: depth,
                                           options: options, log: logFusion)
            }.value
            return true
        } catch {
            dialogs?.notify(message: "Couldn't export the animation",
                            informative: error.localizedDescription, warning: true)
            return false
        }
    }

    /// Output pane coordinate space: full-resolution dimensions regardless of
    /// preview bitmap resolution, so zoom/pan stays in sync with the input pane.
    var outputNominalSize: CGSize? {
        if phase.isRunning { return progressiveNominalSize }
        guard let result else { return nil }
        return CGSize(width: result.width, height: result.height)
    }

    public var inputNominalSize: CGSize? { inputPixelSize }

    // MARK: - Inclusion

    /// Checkbox semantics: toggling a row that's part of a multi-selection
    /// applies the row's new state to every selected row. Frames of
    /// non-selected stacks toggle directly on their Stack.
    public func setIncluded(_ url: URL, to value: Bool) {
        if !frames.contains(url),
           let owner = stacks.first(where: { $0.frames.contains(url) }) {
            objectWillChange.send()
            let before = owner.included
            if value { owner.included.insert(url) } else { owner.included.remove(url) }
            if owner.included != before {
                // Not the selected stack: the edit belongs to *its* history
                // (installed with the stack if it's selected later).
                owner.undoHistory.append(.included(from: before, to: owner.included))
                if owner.undoHistory.count > Self.maxUndoEdits {
                    owner.undoHistory.removeFirst()
                }
                owner.redoHistory = []
            }
            return
        }
        let before = included
        let targets = selection.contains(url) && selection.count > 1 ? selection : [url]
        for target in targets {
            if value { included.insert(target) } else { included.remove(target) }
        }
        if included != before {
            recordEdit(.included(from: before, to: included))
        }
    }

    /// Reads a frame's checkbox through the mirrors for the selected stack.
    public func isIncluded(_ url: URL, in stack: Stack) -> Bool {
        stack.id == selectedStackID ? included.contains(url) : stack.included.contains(url)
    }

    public func frameIssue(_ url: URL, in stack: Stack) -> String? {
        stack.id == selectedStackID ? frameIssues[url] : stack.frameIssues[url]
    }

    /// Frames of a stack as the UI should list them (mirrors for selected).
    public func listedFrames(of stack: Stack) -> [URL] {
        stack.id == selectedStackID ? frames : stack.frames
    }

    func includeAll(_ value: Bool) {
        let before = included
        included = value ? Set(frames) : []
        if included != before {
            recordEdit(.included(from: before, to: included))
        }
    }

    // MARK: - Input preview

    public func selectionChanged() {
        guard let url = frames.first(where: { selection.contains($0) }) ?? selection.first else {
            return  // keep showing the last frame rather than blanking the pane
        }
        // A frame from another stack switches stack selection with it.
        if !frames.contains(url),
           let owner = stacks.first(where: { $0.frames.contains(url) }),
           owner.id != selectedStackID {
            guard !phase.isRunning else { return }
            selectStack(owner.id)   // resets selection to the stack's first…
            selection = [url]       // …then honor the actual click
            showInputFrame(url)
            return
        }
        // In retouch mode the list drives the brush source (and vice versa via
        // onSourceChanged); skip the normal unaligned preview decode.
        if retouchMode, let session = retouch {
            if let index = session.urls.firstIndex(of: url), index != session.sourceIndex {
                session.selectSource(index)
            }
            return
        }
        showInputFrame(url)
    }

    private func showInputFrame(_ url: URL) {
        // Once alignment transforms exist for the fused frame list, the frame
        // is shown warped into the fused canvas (same common-coverage crop the
        // result uses) — a raw decode next to the output reads as misalignment,
        // not as information. Excluded frames and never-fused stacks still get
        // the raw file.
        let alignedURLs = fuseURLs
        let transforms = alignmentCache.transforms(for: alignedURLs)
        let alignedIndex = transforms == nil ? nil : alignedURLs.firstIndex(of: url)
        let aligned = alignedIndex != nil
        guard url != inputPreviewURL || aligned != inputPreviewAligned else { return }
        inputPreviewURL = url
        inputPreviewAligned = aligned
        inputPreviewError = nil
        if let cached = inputCache[url], cached.aligned == aligned {
            inputPreview = cached.image
            inputPixelSize = cached.pixelSize
            inputPreviewLoading = false
            return
        }
        inputDecodeTask?.cancel()
        inputPreviewLoading = true
        inputDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let decoded: (image: PlatformImage, pixelSize: CGSize)? = {
                let buffer: ImageBuffer?
                if let alignedIndex {
                    let source = StackPipeline.makeSource(urls: alignedURLs,
                                                          transforms: transforms)
                    buffer = try? source.frame(at: alignedIndex)
                } else {
                    buffer = try? ImageFile.load(url: url)
                }
                guard let buffer,
                      let cg = try? Preview.image(from: buffer) else { return nil }
                return (cg, CGSize(width: buffer.width, height: buffer.height))
            }()
            let error: String? = decoded != nil ? nil
                : FileManager.default.fileExists(atPath: url.path)
                    ? "Can't decode \(url.lastPathComponent)"
                    : "\(url.lastPathComponent) is missing"
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.inputPreviewURL == url,
                      self.inputPreviewAligned == aligned else { return }
                self.inputPreviewLoading = false
                self.inputPreview = decoded?.image
                self.inputPixelSize = decoded?.pixelSize
                self.inputPreviewError = error
                if let decoded {
                    let entry = (decoded.image, decoded.pixelSize, aligned)
                    if self.inputCache.updateValue(entry, forKey: url) == nil {
                        self.inputCacheOrder.append(url)
                        if self.inputCacheOrder.count > 4 {
                            self.inputCache.removeValue(forKey: self.inputCacheOrder.removeFirst())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Fusion

    public func fuse() {
        guard canFuse else { return }
        // Before any state changes: a cancelled preflight must leave the
        // current result and phase untouched.
        guard preflightDiskCache(urls: includedFrames) else { return }
        phase = .running
        stageText = "Starting…"
        stageFraction = 0
        stageETA = nil
        stageTimerStage = nil
        progressive = nil
        progressiveIsData = false
        progressiveNominalSize = nil
        processingSource = nil
        processingSourceLabel = nil
        processingSourceNominalSize = nil
        retouch = nil
        retouchMode = false
        savedWorking = nil
        savedSourceIndex = nil
        noiseFloorPreview = nil
        noiseFloorPreviewData = nil
        noiseFloorPreviewDataEpoch += 1  // invalidate any in-flight build
        let urls = includedFrames
        // Sources can vanish between fuses (unmounted card, moved folder).
        // Without this check the failure surfaces as an opaque decode error
        // mid-pipeline — or worse, reads as "nothing happened" because the
        // previous result stays on screen.
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            let names = missing.prefix(4).map(\.lastPathComponent).joined(separator: ", ")
            let extra = missing.count > 4 ? " and \(missing.count - 4) more" : ""
            reportFuseFailure("\(missing.count) of \(urls.count) source images are missing "
                + "(moved, renamed, or deleted?): \(names)\(extra). Restore them, or uncheck "
                + "them in the Stack list and re-fuse.")
            return
        }
        fuseURLs = urls
        // Cached aligned previews were warped under the previous fuse list's
        // transforms/crop; a new fuse can change both.
        inputCache = [:]
        inputCacheOrder = []
        // Snapshot NOW, not at completion: the user can move sliders while
        // the fusion runs, and the result must record the settings it was
        // actually fused with — not whatever the UI shows when it finishes
        // (that marked the result "current" at settings it never used).
        let settingsInUse = currentFuseSettings()
        var config = StackPipeline.Configuration()
        config.align = alignFrames
        config.preferGPU = useGPU
        config.fusion = DMapFusion.Options(sharpnessSigma: Float(sharpnessSigma),
                                           blendRadius: Float(blendRadius),
                                           noiseFloor: Float(noiseFloor),
                                           medianRadius: Int(medianRadius),
                                           normalizeExposure: normalizeExposure,
                                           spillEnabled: fusionDiskCache)
        frameIssues = [:]
        // Bad frames (misfires, failed alignment): ask before excluding. The
        // handler runs on the fusion thread; the alert blocks it while the
        // main thread is free, so there's no deadlock. Batches never prompt —
        // an unattended queue must keep moving, so they exclude silently (the
        // summary reports it).
        let dialogs = self.dialogs
        let prompt = badFramePrompt ?? (batchMode ? { _ in true } : { lines in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    dialogs?.confirm(
                        message: lines.count == 1
                            ? "1 frame looks bad" : "\(lines.count) frames look bad",
                        informative: lines.joined(separator: "\n")
                            + "\n\nExcluded frames stay in the Stack list with their checkbox cleared — re-check one to opt back in and re-fuse.",
                        confirmTitle: "Exclude and Continue",
                        cancelTitle: "Keep All Frames",
                        warning: false) ?? true
                }
            }
        })
        config.badFrameHandler = { issues in
            let lines = issues.map { "\(urls[$0.index].lastPathComponent): \($0.summary)" }
            return prompt(lines) ? Set(issues.map(\.index)) : []
        }
        let cache = alignmentCache
        let cancellation = CancellationToken()
        fusionCancellation = cancellation
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try StackPipeline.fuseResult(urls: urls, configuration: config,
                                                          alignmentCache: cache,
                                                          log: logFusion,
                                                          progress: { update in
                    func cgImage(_ buffer: ImageBuffer?) -> PlatformImage? {
                        guard let buffer else { return nil }
                        return try? Preview.image(from: buffer)
                    }
                    let preview = cgImage(update.preview)
                    let nominal = update.previewFullWidth > 0
                        ? CGSize(width: update.previewFullWidth, height: update.previewFullHeight)
                        : nil
                    let source = cgImage(update.sourcePreview)
                    let sourceNominal = update.sourceFullWidth > 0
                        ? CGSize(width: update.sourceFullWidth, height: update.sourceFullHeight)
                        : nil
                    let sourceLabel = urls.indices.contains(update.sourceFrameIndex)
                        ? urls[update.sourceFrameIndex].lastPathComponent
                        : nil
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // After Cancel, in-flight work (decodes already
                        // running when the token flipped) still reports —
                        // those updates must not overwrite "Cancelling…"
                        // or the cancel looks ignored.
                        guard !cancellation.isCancelled else { return }
                        self.stageText = update.stage.rawValue
                        self.updateStageETA(stage: update.stage,
                                            fraction: update.fraction)
                        // One monotonic bar across the whole fuse: each stage
                        // owns a window of the overall span, and the max()
                        // keeps skipped stages (cache hits) from ever
                        // stepping the bar backward.
                        self.stageFraction = max(self.stageFraction,
                                                 Self.overallProgress(update.stage,
                                                                      update.fraction))
                        if let preview {
                            self.progressive = preview
                            self.progressiveIsData = update.stage != .render
                            if let nominal { self.progressiveNominalSize = nominal }
                        }
                        if let source {
                            self.processingSource = source
                            self.processingSourceLabel = sourceLabel
                            if let sourceNominal { self.processingSourceNominalSize = sourceNominal }
                        }
                    }
                }, cancellation: cancellation)
                let output = result.output
                let resultCG = try Preview.image(from: output.image)
                let depthCG = try Preview.image(from: output.depthMap)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Flag bad frames and clear the checkboxes of excluded ones
                    // (they stay listed — re-checking opts back in). fuseURLs
                    // must be what was actually fused: retouch sources, saves,
                    // and exports all key off it.
                    self.frameIssues = Dictionary(uniqueKeysWithValues:
                        result.issues.map { (urls[$0.index], $0.summary) })
                    self.included.subtract(Set(urls).subtracting(result.fusedURLs))
                    self.fuseURLs = result.fusedURLs
                    self.result = output.image
                    self.resultDepth = output.depth
                    self.resultSharpness = output.sharpness
                    self.resultGains = output.gains
                    // What this result was fused with (staleness tracking
                    // for the Fuse buttons) — the start-of-fuse snapshot.
                    self.fusedSettings = settingsInUse
                    self.depthResult = output.depthMap
                    self.outputPreview = resultCG
                    self.depthPreview = depthCG
                    self.progressive = nil
                    self.processingSource = nil
                    self.processingSourceLabel = nil
                    self.hasUnsavedWork = true
                    self.phase = .done
                    // Alignment transforms exist now — swap the Input pane's
                    // raw decode for the aligned one (it sits next to Output).
                    if let url = self.inputPreviewURL {
                        self.inputPreviewURL = nil
                        self.showInputFrame(url)
                    }
                    // Warm the retouch session so Start Retouching opens
                    // with its source already decoded (both shells).
                    if !self.batchMode { self.prepareRetouch() }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.processingSource = nil
                    self.processingSourceLabel = nil
                    self.progressive = nil
                    if error is CancellationError {
                        self.phase = self.frames.isEmpty ? .empty : .loaded
                    } else {
                        self.reportFuseFailure("\(error)")
                    }
                }
            }
        }
    }

    /// A failed fuse must be unmissable: the previous result stays in the
    /// panes (still valid), so without an alert the only sign is a small
    /// warning icon in the Stack list. Batch runs stay silent — an
    /// unattended queue must keep moving; its per-stack status carries the
    /// message.
    /// Testability hook: the probe captures failure messages instead of
    /// blocking on a modal alert (same pattern as badFramePrompt).
    var fuseFailureAlertOverride: ((String) -> Void)?

    func reportFuseFailure(_ message: String) {
        phase = .failed(message)
        guard !batchMode else { return }
        if let fuseFailureAlertOverride {
            fuseFailureAlertOverride(message)
            return
        }
        dialogs?.notify(message: "Fuse failed", informative: message, warning: true)
    }

    /// Maps a per-stage fraction into the fuse's single progress span.
    /// Windows are rough stage-duration weights; registering and aligning
    /// share one span because the engine reports them on one 0…1 fraction.
    /// ETA: time the current stage, extrapolate from its fraction once
    /// there's enough signal to be honest (≥ 2 s elapsed and a real
    /// fraction). Stage changes reset the clock. `now` is injectable so the
    /// probe can drive the timeline deterministically.
    func updateStageETA(stage: FusionProgress.Stage, fraction: Double,
                        now: Date = Date()) {
        if stageTimerStage != stage {
            stageTimerStage = stage
            stageTimerStart = now
            stageETA = nil
        } else if fraction >= 0.04 {
            let elapsed = now.timeIntervalSince(stageTimerStart)
            if elapsed >= 2 {
                stageETA = Self.etaLabel(elapsed / fraction * (1 - fraction))
            }
        }
    }

    /// "~40s left" / "~3 min left" — deliberately coarse (5s / 1 min
    /// steps): the extrapolation is only as steady as the stage's per-frame
    /// cost, and a twitchy countdown reads as broken. Nil under 3s so the
    /// label disappears instead of counting down to a lie.
    static func etaLabel(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 3 else { return nil }
        if seconds < 90 {
            return "~\(max(5, Int((seconds / 5).rounded()) * 5))s left"
        }
        return "~\(Int((seconds / 60).rounded())) min left"
    }

    static func overallProgress(_ stage: FusionProgress.Stage,
                                _ fraction: Double) -> Double {
        let window: (Double, Double)
        switch stage {
        case .registering, .aligning: window = (0.00, 0.45)
        case .depth: window = (0.45, 0.80)
        case .regularizing: window = (0.80, 0.85)
        case .render: window = (0.85, 0.99)
        case .finishing: window = (0.99, 1.00)
        }
        return window.0 + (window.1 - window.0) * min(max(fraction, 0), 1)
    }


    // MARK: - Noise floor preview

    public func beginNoiseFloorPreview() {
        guard phase == .done, let sharpness = resultSharpness, let result,
              !sharpness.planes.isEmpty else { return }
        noiseFloorPreviewActive = true
        if noiseFloorPreviewData != nil {
            updateNoiseFloorPreview()
            return
        }
        guard !noiseFloorPreviewBuilding else { return }
        noiseFloorPreviewBuilding = true
        let epoch = noiseFloorPreviewDataEpoch
        let sw = sharpness.width, sh = sharpness.height
        let planes = sharpness.planes
        let resultImage = result
        // Off-main: the one-time build scans every retained plane and reduces
        // them — seconds of work on a deep stack, and grabbing the slider
        // must not beachball. Ticks arriving before it lands are dropped;
        // the completion runs one update with the current slider value.
        Task.detached(priority: .userInitiated) { [weak self] in
            // Per-pixel argmax across frames (winner energy + index) — the
            // regularizer's inputs, on the retained low-res grid.
            let (energyMax, argmax) = sharpness.winnerPlanes()
            // Guide for the guided regularizer: the fused result's luminance,
            // reduced to the preview grid. The pipeline itself guides on mean
            // stack luminance; the all-in-focus result has the same scene
            // edges and survives project reload (the stack mean isn't
            // retained), so the preview tracks the real regularizer's
            // structure without persisting another plane.
            let guide = DMapFusion.boxDownsample(resultImage.luminancePlane(),
                                                 width: resultImage.width,
                                                 height: resultImage.height,
                                                 factor: DMapFusion.sharpnessDownsample)
            // The guided fit runs on a 2× decimated grid in the preview
            // (per-frame planes and concentration reduced once here): tier-2
            // aggregation is quadratic in grid cells and dominates the tick
            // cost, and at display scale the coarser fit is invisible. The
            // fit's spatial mapping handles the factor natively — this is
            // the same relationship the real pipeline has to full res.
            let halfPlanes = planes.map {
                DMapFusion.boxDownsample($0, width: sw, height: sh, factor: 2)
            }
            let concentration = DMapFusion.peakConcentrationPlane(planes: halfPlanes)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.noiseFloorPreviewBuilding = false
                // A stack switch / re-fuse / reset while building: this data
                // describes the old result — drop it.
                guard epoch == self.noiseFloorPreviewDataEpoch else { return }
                self.noiseFloorPreviewData = (energyMax, argmax, concentration,
                                              halfPlanes, guide, sw, sh,
                                              (sw + 1) / 2, planes.count)
                if self.noiseFloorPreviewActive { self.updateNoiseFloorPreview() }
            }
        }
    }

    public func endNoiseFloorPreview() {
        noiseFloorPreviewActive = false
        noiseFloorPreviewGeneration.bump()  // drop + abort any in-flight compute
        noiseFloorPreviewPending = false
        noiseFloorPreview = nil
    }

    private func updateNoiseFloorPreview() {
        guard let data = noiseFloorPreviewData else { return }
        if noiseFloorPreviewComputing {
            noiseFloorPreviewPending = true
            return
        }
        noiseFloorPreviewComputing = true
        let counter = noiseFloorPreviewGeneration
        let generation = counter.bump()
        var options = DMapFusion.Options(sharpnessSigma: Float(sharpnessSigma),
                                         noiseFloor: Float(noiseFloor),
                                         medianRadius: Int(medianRadius))
        // The preview grid is 1/sharpnessDownsample of full resolution;
        // scale the spatial parameters to match.
        options.medianRadius = options.medianRadius > 0
            ? max(1, options.medianRadius / DMapFusion.sharpnessDownsample) : 0
        options.guidedRadius = max(1, options.guidedRadius
                                      / Float(DMapFusion.sharpnessDownsample))
        // Off-main: the guided fit takes hundreds of ms at deep-stack scale,
        // and slider drags arrive faster than that. Stale results are dropped.
        Task.detached(priority: .userInitiated) { [weak self] in
            let depth = DMapFusion.regularizeDepth(
                bestEnergy: data.energyMax, bestIndex: data.argmax,
                concentration: data.concentration, concentrationWidth: data.halfWidth,
                concentrationFactor: 2,  // guided fit on the 2× preview grid
                planes: data.planes,
                guide: data.guide,
                width: data.width, height: data.height,
                frameCount: data.frames, options: options,
                isStale: { generation != counter.current() })
            let image = DMapFusion.depthImage(from: depth, width: data.width,
                                              height: data.height,
                                              frameCount: data.frames)
            let cg = try? Preview.image(from: image)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.noiseFloorPreviewComputing = false
                defer {
                    // A drag tick landed mid-compute: run once more with the
                    // latest slider value.
                    if self.noiseFloorPreviewPending {
                        self.noiseFloorPreviewPending = false
                        if self.noiseFloorPreviewActive { self.updateNoiseFloorPreview() }
                    }
                }
                guard let cg, generation == counter.current() else { return }
                self.noiseFloorPreview = cg
            }
        }
    }

    public func cancelFusion() {
        fusionCancellation?.cancel()
        stageText = "Cancelling…"
        stageETA = nil
    }

    // MARK: - Retouching

    public func enterRetouch() {
        guard result != nil, phase == .done, !resultDepth.isEmpty else { return }
        prepareRetouch()
        retouchMode = true
        // Sync the list to the session's current source immediately.
        if let session = retouch, session.urls.indices.contains(session.sourceIndex) {
            selection = [session.urls[session.sourceIndex]]
        }
    }

    /// Build the retouch session ahead of need — the constructor kicks
    /// the initial aligned-source decode, so warming this right after a
    /// fuse means Start Retouching opens with the source already in
    /// hand instead of a "Loading source…" wait. Idempotent; both
    /// shells share it (called from fuse completion and enterRetouch).
    public func prepareRetouch() {
        guard let result, phase == .done, !resultDepth.isEmpty else { return }
        if retouch == nil {
            // Rebuild the exact source configuration the fusion used (same
            // common-coverage crop) so aligned slices match the result.
            var source = StackPipeline.makeSource(
                urls: fuseURLs, transforms: alignmentCache.transforms(for: fuseURLs))
            // Same exposure gains too, so stamps don't reintroduce flicker.
            source.gains = resultGains
            if let w = source.outputWidth, let h = source.outputHeight,
               w != result.width || h != result.height {
                // Should be impossible (same deterministic crop as the fusion);
                // if it ever happens, say so instead of misaligning retouch.
                FileHandle.standardError.write(Data(
                    "retouch: source canvas \(w)x\(h) != result \(result.width)x\(result.height)\n".utf8))
            }
            retouch = RetouchSession(result: result, depth: resultDepth,
                                     sharpness: resultSharpness, source: source,
                                     restoredWorking: savedWorking,
                                     initialSourceIndex: savedSourceIndex)
            retouch?.onEdited = { [weak self] in self?.hasUnsavedWork = true }
            retouch?.onSourceChanged = { [weak self] index in
                guard let self, let session = self.retouch,
                      session.urls.indices.contains(index) else { return }
                self.selection = [session.urls[index]]
            }
        }
    }

    public func exitRetouch() {
        retouchMode = false
        // Reflect the edits in the normal output view (and export).
        if let session = retouch, session.hasEdits,
           let snapshot = session.makeSnapshotImage() {
            outputPreview = snapshot
        }
        mergeRetouchDepth()
    }

    /// Retouch strokes co-paint the depth plane (that's what makes depth
    /// artifacts in the rocking animation fixable) — fold the session's
    /// depth back into the model and refresh the visualizations. Called
    /// wherever the session's working image is consumed: stash (which
    /// covers saves and stack switches), retouch exit, and the depth /
    /// animation output paths.
    private func mergeRetouchDepth() {
        guard let session = retouch, session.depthDirty else { return }
        session.markDepthMerged()
        resultDepth = session.workingDepth
        let image = DMapFusion.depthImage(from: resultDepth,
                                          width: session.width,
                                          height: session.height,
                                          frameCount: max(session.urls.count, 2))
        depthResult = image
        if let cg = try? Preview.image(from: image) {
            depthPreview = cg
        }
    }

    public func resetRetouch() {
        guard let result else { return }
        retouch?.resetAll(to: result)
    }

    // MARK: - Export

    func exportResult() {
        afterUpdate { $0.runExportPanel() }
    }

    private func runExportPanel() {
        // Retouch edits, once made, are the result.
        let baseImage = retouch?.hasEdits == true ? retouch?.working : (savedWorking ?? result)
        guard (outputMode == .depth ? depthResult : baseImage) != nil else { return }
        // Name after the stack's folder — stable and meaningful, unlike
        // whichever frame happens to be first or selected.
        let base = (fuseURLs.first ?? frames.first)?
            .deletingLastPathComponent().lastPathComponent ?? "stacked"
        let suffix = outputMode == .depth ? " depth" : ""
        guard let url = dialogs?.chooseSaveExport(
            suggestedName: "\(base)\(suffix).\(exportFormat.fileExtension)") else { return }
        writeExport(to: url)
    }

    /// The crop clamped to an image's bounds — nil when it doesn't
    /// meaningfully intersect (e.g. a stale crop after re-fusing produced a
    /// different canvas). Every output path and the panes go through this,
    /// so they can't disagree about what the crop means.
    nonisolated static func validCrop(_ crop: CGRect?, width: Int, height: Int) -> CGRect? {
        guard let crop else { return nil }
        let bounded = crop.integral.intersection(
            CGRect(x: 0, y: 0, width: width, height: height))
        guard bounded.width >= 16, bounded.height >= 16 else { return nil }
        return bounded
    }

    /// Pointer smuggling for DispatchQueue.concurrentPerform: the rows
    /// written are disjoint per iteration, so sharing the buffers across
    /// the @Sendable closures is safe — the types just can't say so.
    private struct UnsafeSendableBox<T>: @unchecked Sendable { let value: T }

    nonisolated static func cropped(_ image: ImageBuffer, to crop: CGRect?,
                                    angle: Double = 0) -> ImageBuffer {
        guard let r = validCrop(crop, width: image.width, height: image.height) else {
            return image
        }
        guard angle != 0 else {
            return image.cropped(x: Int(r.minX), y: Int(r.minY),
                                 width: Int(r.width), height: Int(r.height))
        }
        // Rotated crop: the output is the axis-aligned rect sampled from the
        // image rotated by the angle about the rect's center — bilinear,
        // edge-clamped (matching the panes' presentation).
        let w = Int(r.width), h = Int(r.height)
        let srcW = image.width, srcH = image.height
        let cx = Float(r.midX), cy = Float(r.midY)
        let rad = Float(angle) * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        let x0f = Float(r.minX), y0f = Float(r.minY)
        var out = ImageBuffer(width: w, height: h)
        image.pixels.withUnsafeBufferPointer { srcRaw in
            out.pixels.withUnsafeMutableBufferPointer { dstRaw in
                let srcBox = UnsafeSendableBox(value: srcRaw)
                let dstBox = UnsafeSendableBox(value: dstRaw)
                DispatchQueue.concurrentPerform(iterations: h) { v in
                    let src = srcBox.value, dst = dstBox.value
                    let dy = y0f + Float(v) + 0.5 - cy
                    for u in 0..<w {
                        let dx = x0f + Float(u) + 0.5 - cx
                        let sx = min(max(cx + dx * cosA - dy * sinA - 0.5, 0), Float(srcW - 1))
                        let sy = min(max(cy + dx * sinA + dy * cosA - 0.5, 0), Float(srcH - 1))
                        let ix = Int(sx), iy = Int(sy)
                        let ix1 = min(ix + 1, srcW - 1), iy1 = min(iy + 1, srcH - 1)
                        let fx = sx - Float(ix), fy = sy - Float(iy)
                        let a = (iy * srcW + ix) * 4, b = (iy * srcW + ix1) * 4
                        let c = (iy1 * srcW + ix) * 4, e = (iy1 * srcW + ix1) * 4
                        let di = (v * w + u) * 4
                        for ch in 0..<3 {
                            let top = src[a + ch] + (src[b + ch] - src[a + ch]) * fx
                            let bot = src[c + ch] + (src[e + ch] - src[c + ch]) * fx
                            dst[di + ch] = top + (bot - top) * fy
                        }
                        dst[di + 3] = 1
                    }
                }
            }
        }
        return out
    }

    /// The depth plane cropped (and rotated) in step with its image.
    nonisolated static func croppedDepth(_ depth: [Float], width: Int, height: Int,
                             to crop: CGRect?, angle: Double = 0) -> [Float] {
        guard let r = validCrop(crop, width: width, height: height) else { return depth }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        guard angle != 0 else {
            var out = [Float]()
            out.reserveCapacity(w * h)
            for y in y0..<(y0 + h) {
                out.append(contentsOf: depth[(y * width + x0)..<(y * width + x0 + w)])
            }
            return out
        }
        let cx = Float(r.midX), cy = Float(r.midY)
        let rad = Float(angle) * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        var out = [Float](repeating: 0, count: w * h)
        depth.withUnsafeBufferPointer { srcRaw in
            out.withUnsafeMutableBufferPointer { dstRaw in
                let srcBox = UnsafeSendableBox(value: srcRaw)
                let dstBox = UnsafeSendableBox(value: dstRaw)
                DispatchQueue.concurrentPerform(iterations: h) { v in
                    let src = srcBox.value, dst = dstBox.value
                    let dy = Float(y0 + v) + 0.5 - cy
                    for u in 0..<w {
                        let dx = Float(x0 + u) + 0.5 - cx
                        let sx = Int(min(max(cx + dx * cosA - dy * sinA, 0), Float(width - 1)))
                        let sy = Int(min(max(cy + dx * sinA + dy * cosA, 0), Float(height - 1)))
                        dst[v * w + u] = src[sy * width + sx]
                    }
                }
            }
        }
        return out
    }

    /// Panel-free export: the write body of exportResult, honoring the
    /// current format/color-space/tone/output-mode state. Callable directly
    /// (UITestSupport's command channel).
    @discardableResult
    public func writeExport(to url: URL) -> Bool {
        if outputMode == .depth { mergeRetouchDepth() }
        let baseImage = retouch?.hasEdits == true ? retouch?.working : (savedWorking ?? result)
        guard let raw = outputMode == .depth ? depthResult : baseImage else { return false }
        let image = Self.cropped(raw, to: cropRect, angle: cropAngle)
        do {
            // Tone bakes into display-referred formats only: DNG stays
            // linear for raw development, and the depth map is data.
            var toned = image
            if outputMode != .depth, exportFormat != .dng {
                ToneCurve.apply(settings: tone, to: &toned)
            }
            try Self.saveImage(toned, to: url, sourceFrame: fuseURLs.first,
                               colorSpace: exportColorSpace)
            if outputMode != .depth, exportFormat == .dng, !tone.isNeutral {
                // DNG stays linear; the tone rides along as embedded Camera
                // Raw XMP, which Lightroom/ACR read as develop settings.
                try XMPSidecar.embed(tone: tone, inDNGAt: url)
            }
            return true
        } catch {
            // Same rule as saveProjectPanel: a failed write doesn't
            // invalidate the fused result, so don't touch `phase`.
            dialogs?.notify(message: "Couldn't export the image",
                            informative: error.localizedDescription, warning: true)
            return false
        }
    }

}
