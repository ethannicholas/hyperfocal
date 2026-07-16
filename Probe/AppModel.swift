import SwiftUI
import HyperfocalKit
import UniformTypeIdentifiers
import os

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
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case empty
        case loaded
        case running
        case done
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    enum OutputMode: String, CaseIterable {
        case result = "Result"
        case depth = "Depth"
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case tiff = "TIFF (16-bit)"
        case dng = "DNG (raw)"
        case png = "PNG (16-bit)"
        case jpeg = "JPEG"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .tiff: return "tif"
            case .dng: return "dng"
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    enum ExportColorSpace: String, CaseIterable, Identifiable {
        case srgb = "sRGB"
        case displayP3 = "Display P3"
        case prophoto = "ProPhoto RGB"

        var id: String { rawValue }

        var cgColorSpace: CGColorSpace? {
            switch self {
            case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)
            case .displayP3: return nil  // the working space; no conversion
            case .prophoto: return CGColorSpace(name: CGColorSpace.rommrgb)
            }
        }
    }

    @Published var phase: Phase = .empty
    @Published var frames: [URL] = []
    @Published var included: Set<URL> = []
    @Published var selection: Set<URL> = []
    /// Frames the last fuse flagged as bad, with the reason ("4.1× darker than
    /// the stack") — shown as a warning badge in the Stack list. Excluded
    /// frames stay listed with their checkbox cleared, so opting back in is
    /// just re-checking them.
    @Published var frameIssues: [URL: String] = [:]
    /// Decides whether flagged frames get excluded (called off the main thread
    /// with display lines). Defaults to a blocking alert; the headless probe
    /// replaces it. Read once at fuse start.
    var badFramePrompt: (([String]) -> Bool)?

    // Multi-stack project. AppModel's frame/result fields below always mirror
    // the *selected* stack (so the whole single-stack pipeline — fuse,
    // retouch, preview — operates unchanged); `selectStack` stashes the
    // mirrors into the outgoing Stack and installs the incoming one.
    @Published private(set) var stacks: [Stack] = []
    @Published var selectedStackID: UUID?
    @Published var expandedStacks: Set<UUID> = []
    var selectedStack: Stack? { stacks.first { $0.id == selectedStackID } }

    enum StackStatus {
        case unfused, fusing, fused, failed(String)
    }

    // Queue ("Fuse Enabled Stacks") progress prefix, e.g. "Stack 2 of 5 · ".
    @Published var batchStatus: String?
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
    static let settings = UserDefaults(
        suiteName: ProcessInfo.processInfo.environment["HYPERFOCAL_UITEST"] == "1"
            ? "org.hyperfocal.uitest-settings"
            : "org.hyperfocal.settings") ?? .standard

    // Fusion parameters
    @Published var alignFrames: Bool {
        didSet { Self.settings.set(alignFrames, forKey: "alignFrames") }
    }
    @Published var useGPU: Bool {
        didSet { Self.settings.set(useGPU, forKey: "useGPU") }
    }
    /// Fusion's temporary disk cache (FrameSpill): caches aligned frames
    /// between the two depth-fusion passes so the stack isn't decoded twice.
    /// Output is bit-identical either way — the toggle exists for machines
    /// short on disk (the cache is width×height×16 bytes per frame).
    @Published var fusionDiskCache: Bool {
        didSet { Self.settings.set(fusionDiskCache, forKey: "fusionDiskCache") }
    }
    // The fusion sliders are per-project creative controls, deliberately
    // not persisted: with the defaults dialed in, every new project starts
    // from them (the set-and-forget switches below stay persisted).
    @Published var sharpnessSigma = defaultSharpnessSigma
    @Published var noiseFloor: Double = AppModel.defaultNoiseFloor {
        didSet {
            if noiseFloorPreviewActive { updateNoiseFloorPreview() }
        }
    }
    @Published var medianRadius = defaultMedianRadius
    @Published var blendRadius = defaultBlendRadius
    @Published var normalizeExposure: Bool {
        didSet { Self.settings.set(normalizeExposure, forKey: "normalizeExposure") }
    }
    /// Order each stack's frames by EXIF capture time at load (filename
    /// order breaks when the camera's file counter rolls over mid-stack).
    /// Off = filename always wins. Read at load time, not fuse time.
    @Published var orderByCaptureTime: Bool {
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
    @Published var stageText = ""
    @Published var stageFraction = 0.0
    @Published var progressive: NSImage?
    @Published var progressiveNominalSize: CGSize?
    @Published var processingSource: NSImage?
    @Published var processingSourceLabel: String?
    @Published var processingSourceNominalSize: CGSize?

    // Results & previews
    @Published var outputPreview: NSImage?
    @Published var depthPreview: NSImage?
    @Published var inputPreview: NSImage?
    @Published var inputPreviewURL: URL?
    /// The preview is warped into the fused canvas (alignment transforms
    /// existed when it was decoded) rather than the raw file.
    @Published var inputPreviewAligned = false
    @Published var inputPreviewLoading = false
    /// Why the selected frame couldn't be shown (missing file, decode failure).
    /// Without this the pane falls back to the "select a frame" hint, which is
    /// misleading when a frame IS selected but its volume is unmounted.
    @Published var inputPreviewError: String?
    /// True pixel dimensions of the input preview. Do NOT derive this from the
    /// NSImage: NSCGImageSnapshotRep reports pixelsWide at the display's backing
    /// scale (2x on Retina), which broke pane synchronization.
    @Published var inputPixelSize: CGSize?
    @Published var outputMode: OutputMode = .result
    /// Lightroom-style tone adjustments (per stack, saved in projects):
    /// live on every preview — panes and retouch canvas — and baked into
    /// TIFF/PNG/JPEG exports at full float precision before quantization.
    /// Linear DNG ignores them by design: that format hands unmodified
    /// linear data to a real raw developer.
    @Published var tone = ToneSettings() {
        didSet {
            guard oldValue != tone else { return }
            if !installingStack { hasUnsavedWork = true }
        }
    }
    /// Guards `tone.didSet` against marking stack switches as unsaved edits.
    private var installingStack = false
    @Published var exportFormat: ExportFormat {
        didSet { Self.settings.set(exportFormat.rawValue, forKey: "exportFormat") }
    }
    @Published var exportColorSpace: ExportColorSpace {
        didSet { Self.settings.set(exportColorSpace.rawValue, forKey: "exportColorSpace") }
    }

    let viewport = ViewportState()
    private let alignmentCache = AlignmentCache()

    // Retouching
    @Published var retouchMode = false
    @Published var retouch: RetouchSession?
    private(set) var resultDepth: [Float] = []
    private(set) var resultSharpness: FrameSharpness?
    // Exposure gains the fusion applied; retouch sources must match them.
    private(set) var resultGains: [Float]?
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
    @Published var noiseFloorPreview: NSImage?
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
    private(set) var hasUnsavedWork = false
    /// The file the current project was opened from or last saved to —
    /// File > Save writes straight back to it; nil (never saved, or project
    /// closed) makes Save fall through to Save As. The open/save panels'
    /// sandbox grants cover the URL for the app's lifetime, so in-place
    /// re-saves need no new grant. Published: the window title shows it.
    @Published private(set) var projectURL: URL?

    // Security-scoped file access (the app is sandboxed; frames live outside
    // the container). `grantedRoots` are the URLs the user granted this
    // session — open-panel/drop selections, or bookmark-resolved roots after
    // a restore — and are what gets bookmarked into saved projects.
    // `scopedAccessURLs` are the roots we called startAccessing... on,
    // balanced with stopAccessing when the project is replaced.
    private var grantedRoots: [URL] = []
    private var scopedAccessURLs: [URL] = []

    init() {
        let d = Self.settings
        exportFormat = d.string(forKey: "exportFormat")
            .flatMap { ExportFormat(rawValue: $0) } ?? .tiff
        exportColorSpace = d.string(forKey: "exportColorSpace")
            .flatMap { ExportColorSpace(rawValue: $0) } ?? .srgb
        alignFrames = d.object(forKey: "alignFrames") as? Bool ?? true
        useGPU = (d.object(forKey: "useGPU") as? Bool ?? true) && MetalEngine.shared != nil
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
    }

    private func stopScopedAccess() {
        for url in scopedAccessURLs { url.stopAccessingSecurityScopedResource() }
        scopedAccessURLs = []
    }

    /// Resolves saved bookmarks and starts access. `remap` translates a moved
    /// or renamed root's stored path prefix to where the bookmark found it, so
    /// persisted frame paths keep working. Staleness needs no handling here:
    /// the next save re-creates bookmarks from the resolved roots.
    nonisolated private static func resolveScopedAccess(_ bookmarks: [String: Data]?)
        -> (roots: [URL], accessed: [URL], remap: [String: String]) {
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
        installingStack = false
        outputPreview = stack.outputPreview
        depthPreview = stack.depthPreview
        savedWorking = stack.savedWorking
        savedSourceIndex = stack.savedSourceIndex
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

    func selectStack(_ id: UUID) {
        guard id != selectedStackID, !phase.isRunning,
              let target = stacks.first(where: { $0.id == id }) else { return }
        if let current = selectedStack { stash(into: current) }
        selectedStackID = id
        install(from: target)
    }

    /// Live status for the tree's glyphs: the selected stack reads the
    /// mirrors (its Stack object is stale until stashed).
    func status(of stack: Stack) -> StackStatus {
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

    func setStackEnabled(_ id: UUID, to value: Bool) {
        guard let stack = stacks.first(where: { $0.id == id }) else { return }
        objectWillChange.send()
        stack.enabled = value
    }

    /// File > Close Stack: removes the selected stack from the project. Its
    /// fused result and retouch edits go with it (they can't be recomputed),
    /// so a fused stack asks first unless everything is already saved.
    func closeSelectedStack() {
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
    func closeProject() {
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

    var fusedStackCount: Int {
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
    var pendingStackCount: Int {
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
                fusedSettings: stack.fusedSettings,
                tone: stack.tone.isNeutral ? nil : stack.tone)
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
    func confirmDiscardingUnsavedWork(message: String, confirmTitle: String) -> Bool {
        guard hasUnsavedWork, fusedStackCount > 0, !phase.isRunning else { return true }
        return runConfirmAlert(message: message,
                               informative: "Any unsaved work will be lost.",
                               confirmTitle: confirmTitle)
    }

    /// Testability hook: when set, confirmation alerts are answered by the
    /// closure (keyed on the message) instead of blocking on NSAlert — the
    /// probe exercises close/replace flows headlessly through this.
    var confirmAlertOverride: ((String) -> Bool)?

    private func runConfirmAlert(message: String, informative: String,
                                 confirmTitle: String) -> Bool {
        if let confirmAlertOverride { return confirmAlertOverride(message) }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
            informative: "Fusing normally caches aligned frames in a temporary file "
                + "so the stack isn't decoded twice — this stack needs about "
                + "\(fmt(short.needed)) and the disk has \(fmt(short.available)) free. "
                + "Fusing works without the cache, just slower. You can also free up "
                + "space, or turn the cache off in Settings.",
            confirmTitle: "Fuse Anyway")
    }

    func confirmTermination() -> NSApplication.TerminateReply {
        guard hasUnsavedWork, fusedStackCount > 0, !phase.isRunning else { return .terminateNow }
        return runConfirmAlert(message: "Are you sure you want to quit?",
                               informative: "Unsaved data will be lost.",
                               confirmTitle: "Quit")
            ? .terminateNow : .terminateCancel
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
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ProjectStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        if let projectURL {
            // Saving-as from a saved project starts where the project lives.
            panel.directoryURL = projectURL.deletingLastPathComponent()
            panel.nameFieldStringValue = projectURL.lastPathComponent
        } else {
            let base = stacks.first?.name ?? "Project"
            panel.nameFieldStringValue = "\(base).\(ProjectStore.fileExtension)"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeProject(to: url)
    }

    /// Panel-free save: the write body of saveProject/saveProjectAs,
    /// callable directly (UITestSupport, and any future probe checks).
    @discardableResult
    func writeProject(to url: URL) -> Bool {
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
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save the project"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    func openProjectPanel() {
        afterUpdate { $0.runOpenProjectPanel() }
    }

    private func runOpenProjectPanel() {
        guard confirmDiscardingUnsavedWork(message: "Open a different project?",
                                           confirmTitle: "Open Project") else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: ProjectStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(from: url)
    }

    private struct RestoredStack {
        let payload: ProjectStore.StackPayload
        let outputCG: CGImage?
        let depthCG: CGImage?
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
                    var outputCG: CGImage? = nil
                    var depthCG: CGImage? = nil
                    var depthImage: ImageBuffer? = nil
                    if let result = payload.result {
                        outputCG = try ImageFile.cgImage8(from: payload.working ?? result)
                        let image = DMapFusion.depthImage(
                            from: payload.depth, width: result.width, height: result.height,
                            frameCount: max(payload.includedURLs.count, 2))
                        depthImage = image
                        depthCG = try ImageFile.cgImage8(from: image)
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
            stack.fusedSettings = item.payload.fusedSettings
            stack.tone = item.payload.tone ?? ToneSettings()
            stack.depthResult = item.depthImage
            stack.savedWorking = item.payload.working
            stack.savedSourceIndex = item.payload.sourceIndex
            stack.outputPreview = item.outputCG.map { NSImage(cgImage: $0, size: .zero) }
            stack.depthPreview = item.depthCG.map { NSImage(cgImage: $0, size: .zero) }
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

    private(set) var result: ImageBuffer?
    private(set) var depthResult: ImageBuffer?
    private var inputCache: [URL: (image: NSImage, pixelSize: CGSize, aligned: Bool)] = [:]
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

    var fusionSettingsAreDefault: Bool {
        sharpnessSigma == Self.defaultSharpnessSigma
            && noiseFloor == Self.defaultNoiseFloor
            && medianRadius == Self.defaultMedianRadius
            && blendRadius == Self.defaultBlendRadius
    }

    func resetFusionSettings() {
        sharpnessSigma = Self.defaultSharpnessSigma
        noiseFloor = Self.defaultNoiseFloor
        medianRadius = Self.defaultMedianRadius
        blendRadius = Self.defaultBlendRadius
    }

    var canFuse: Bool {
        includedFrames.count >= 2 && !phase.isRunning
            && (selectedStack?.enabled ?? true)
            && (selectedStack.map { needsRefuse($0) } ?? true)
    }
    var canExport: Bool { result != nil && !phase.isRunning }

    /// The image size the synced preview panes are currently showing —
    /// what menu-driven zoom should anchor to.
    var displayedImageSize: CGSize {
        retouch?.nominalSize ?? outputNominalSize ?? inputNominalSize
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a stack: a folder of frames, or the frames themselves (focus order = name order)."
        guard panel.runModal() == .OK else { return }
        ingest(urls: panel.urls)
    }

    func addStackFolderPanel() {
        afterUpdate { $0.runAddStackFolderPanel() }
    }

    private func runAddStackFolderPanel() {
        guard !phase.isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Add stack folders to the project — each folder of frames becomes its own stack."
        guard panel.runModal() == .OK else { return }
        loadStacks(from: panel.urls, replacing: false)
    }

    func ingest(urls: [URL]) {
        loadStacks(from: urls, replacing: true)
    }

    /// Drag-and-drop lands here: drops *add* stacks (like Add Stack Folder…)
    /// rather than replacing the project, so they never discard work and
    /// never need to warn. A dropped project file is the exception — that
    /// means "open this project", which replaces and therefore confirms.
    func addStacks(urls: [URL]) {
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
        -> [(name: String, frames: [URL], bursts: [[URL]])] {
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
        // One EXIF pass per group feeds both the frame order and the burst
        // split (hundreds of header reads on a card load — don't do it twice).
        return groups.map { group in
            let dates = group.frames.map(StackSplitter.captureDate(of:))
            return (group.name,
                    StackSplitter.ordered(urls: group.frames, dates: dates,
                                          byCaptureTime: orderByCaptureTime),
                    StackSplitter.split(urls: group.frames, dates: dates,
                                        gap: StackSplitter.defaultGap,
                                        orderByCaptureTime: orderByCaptureTime))
        }
    }

    private func installScanned(_ groups: [(name: String, frames: [URL], bursts: [[URL]])],
                                replacing: Bool) {
        var splitChoice: Bool? = nil  // asked at most once per load
        var newStacks = [Stack]()
        for group in groups {
            if group.bursts.filter({ $0.count >= 2 }).count >= 2 {
                if splitChoice == nil {
                    splitChoice = askSplitChoice(name: group.name,
                                                 burstCount: group.bursts.count)
                }
                if splitChoice == true {
                    for (i, burst) in group.bursts.enumerated() {
                        newStacks.append(Stack(name: "\(group.name) \(i + 1)", frames: burst))
                    }
                    continue
                }
            }
            newStacks.append(Stack(name: group.name, frames: group.frames))
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
        let alert = NSAlert()
        alert.messageText = "“\(name)” looks like \(burstCount) separate stacks"
        alert.informativeText = "Capture times show \(burstCount) bursts separated by more than \(Int(StackSplitter.defaultGap)) seconds. Load them as separate stacks, or keep each folder as one stack?\n\nThis choice applies to every folder in this load."
        alert.addButton(withTitle: "Separate Stacks")
        alert.addButton(withTitle: "One Stack per Folder")
        return alert.runModal() == .alertFirstButtonReturn
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

    private func resetForNewProject() {
        // Cached alignments must die with the project: a re-opened stack
        // should register fresh, not silently reuse transforms from a
        // previous session's load. (Project restore re-seeds the cache from
        // the stored transforms after this runs.)
        alignmentCache.removeAll()
        resetFusionSettings()
        stacks = []
        selectedStackID = nil
        expandedStacks = []
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
    func fuseEnabledStacks() {
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
                    let alert = NSAlert()
                    alert.messageText = "Some stacks didn't fuse"
                    alert.informativeText = summary
                    alert.runModal()
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Every fused stack is written to this folder."
        panel.accessoryView = ExportOptionsView(model: self, panel: nil)
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summary = await self.exportAllFused(to: dir)
            if let presenter = self.queueSummaryPresenter {
                presenter(summary)
            } else {
                let alert = NSAlert()
                alert.messageText = "Export finished"
                alert.informativeText = summary
                alert.runModal()
            }
        }
    }

    /// Writes every fused stack (retouch edits included) to `directory` in the
    /// current export format and color space. Returns a summary line per stack.
    func exportAllFused(to directory: URL) async -> String {
        if let current = selectedStack { stash(into: current) }
        let ext = exportFormat.fileExtension
        let space = exportColorSpace.cgColorSpace
        var lines = [String]()
        var count = 0
        for stack in stacks {
            guard let image = stack.savedWorking ?? stack.result else { continue }
            let dest = directory.appendingPathComponent("\(stack.name).\(ext)")
            let sourceFrame = stack.fuseURLs.first
            let tone = exportFormat == .dng ? ToneSettings() : stack.tone
            do {
                let stackTone = stack.tone ?? ToneSettings()
                let wantsSidecar = exportFormat == .dng && !stackTone.isNeutral
                try await Task.detached(priority: .userInitiated) {
                    var toned = image
                    ToneCurve.apply(settings: tone, to: &toned)
                    try ImageFile.save(toned, to: dest, sourceFrame: sourceFrame,
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
    var canExportAligned: Bool {
        !phase.isRunning && alignmentCache.transforms(for: fuseURLs) != nil
            && selection.contains { fuseURLs.contains($0) }
    }

    func exportAlignedFramesPanel() {
        afterUpdate { $0.runExportAlignedPanel() }
    }

    private func runExportAlignedPanel() {
        guard canExportAligned else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "The selected frames are written to this folder, aligned to the fused canvas."
        panel.accessoryView = ExportOptionsView(model: self, panel: nil)
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summary = await self.exportAlignedFrames(to: dir)
            if let presenter = self.queueSummaryPresenter {
                presenter(summary)
            } else {
                let alert = NSAlert()
                alert.messageText = "Export finished"
                alert.informativeText = summary
                alert.runModal()
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
    func exportAlignedFrames(to directory: URL) async -> String {
        let alignedURLs = fuseURLs
        guard let transforms = alignmentCache.transforms(for: alignedURLs) else {
            return "No alignment yet — fuse the stack (with alignment on) first."
        }
        let targets = frames.filter { selection.contains($0) && alignedURLs.contains($0) }
        let ext = exportFormat.fileExtension
        let space = exportColorSpace.cgColorSpace
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
                try await Task.detached(priority: .userInitiated) {
                    var image = try source.frame(at: index)
                    ToneCurve.apply(settings: bakedTone, to: &image)
                    try ImageFile.save(image, to: dest, sourceFrame: url,
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

    /// Format + color-space pickers hosted inside the export dialogs
    /// (Photoshop-style: the options live next to the decision they affect,
    /// not in the main window). Bound to the same persisted settings the
    /// engine reads, so dialogs remember the last choice; on a save panel,
    /// switching format retargets the allowed content type so the filename
    /// extension follows.
    final class ExportOptionsView: NSView {
        private weak var model: AppModel?
        private weak var panel: NSSavePanel?
        private let formatPopup = NSPopUpButton()
        private let spacePopup = NSPopUpButton()

        /// What the color-space popup reads while DNG is selected: DNG
        /// always carries linear P3, and a disabled popup frozen on the
        /// previous choice would read as "DNG uses sRGB and you can't
        /// change it".
        private static let dngSpaceTitle = "Linear Display P3"

        init(model: AppModel, panel: NSSavePanel?) {
            self.model = model
            self.panel = panel
            super.init(frame: .zero)
            for format in ExportFormat.allCases {
                formatPopup.addItem(withTitle: format.rawValue)
            }
            formatPopup.selectItem(withTitle: model.exportFormat.rawValue)
            formatPopup.target = self
            formatPopup.action = #selector(formatChanged)
            formatPopup.setAccessibilityIdentifier("export.format")
            for space in ExportColorSpace.allCases {
                spacePopup.addItem(withTitle: space.rawValue)
            }
            spacePopup.target = self
            spacePopup.action = #selector(spaceChanged)
            spacePopup.setAccessibilityIdentifier("export.color-space")
            spacePopup.toolTip = "The pipeline works in Display P3. sRGB is the safe default for sharing; Display P3 keeps the full working gamut; ProPhoto suits further heavy editing. DNG always carries the full P3 gamut as linear raw."

            // Fixed frames, NO Auto Layout: sandboxed save panels are remote,
            // and the bridge polls the accessory's constraint-based fitting
            // size every frame — a baseline-aligned NSGridView never
            // converges, so an idle panel re-solved constraints forever
            // (~30% CPU). Plain frames give the bridge a constant answer.
            // Width is computed with the widest spacePopup contents (the DNG
            // placeholder) present so refresh() never changes any frame.
            let labelFormat = NSTextField(labelWithString: "Format:")
            let labelSpace = NSTextField(labelWithString: "Color space:")
            spacePopup.addItem(withTitle: Self.dngSpaceTitle)
            for control in [labelFormat, labelSpace, formatPopup, spacePopup] {
                control.sizeToFit()
            }
            spacePopup.removeItem(at: spacePopup.numberOfItems - 1)
            let pad: CGFloat = 20, vpad: CGFloat = 12
            let gap: CGFloat = 8, rowGap: CGFloat = 6
            let labelW = max(labelFormat.frame.width, labelSpace.frame.width)
            let popupW = max(formatPopup.frame.width, spacePopup.frame.width)
            let rowH = max(formatPopup.frame.height, spacePopup.frame.height)
            let size = NSSize(width: pad + labelW + gap + popupW + pad,
                              height: vpad + rowH * 2 + rowGap + vpad)
            func place(_ label: NSTextField, _ popup: NSPopUpButton, rowFromTop: Int) {
                let y = size.height - vpad - rowH - CGFloat(rowFromTop) * (rowH + rowGap)
                popup.frame = NSRect(x: pad + labelW + gap, y: y,
                                     width: popupW, height: rowH)
                label.frame.origin = NSPoint(
                    x: pad + labelW - label.frame.width,
                    y: y + (rowH - label.frame.height) / 2)
                addSubview(label)
                addSubview(popup)
            }
            place(labelFormat, formatPopup, rowFromTop: 0)
            place(labelSpace, spacePopup, rowFromTop: 1)
            // Frame FIRST, masks after: autoresizing redistributes margins on
            // every resize, so growing the view from its .zero init frame
            // with flexible masks already set scrambles the placement (all
            // controls piled up at one spot). Rigid placement + final frame,
            // THEN the masks that pin the block top-left while the panel
            // stretches the accessory to its own width and height.
            frame = NSRect(origin: .zero, size: size)
            for view in subviews {
                view.autoresizingMask = [.maxXMargin, .minYMargin]
            }
            // Flexible width on the accessory ITSELF: a rigid view can't be
            // stretched by the panel, which centers it instead — the whole
            // block floated to the middle regardless of the internal layout.
            autoresizingMask = .width
            refresh()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        @objc private func formatChanged() {
            guard let model, let format = ExportFormat(
                rawValue: formatPopup.titleOfSelectedItem ?? "") else { return }
            model.exportFormat = format
            if let type = UTType(filenameExtension: format.fileExtension) {
                panel?.allowedContentTypes = [type]
            }
            refresh()
        }

        @objc private func spaceChanged() {
            guard let model, let space = ExportColorSpace(
                rawValue: spacePopup.titleOfSelectedItem ?? "") else { return }
            model.exportColorSpace = space
        }

        private func refresh() {
            guard let model else { return }
            let dng = model.exportFormat == .dng
            spacePopup.isEnabled = !dng
            if dng {
                if spacePopup.item(withTitle: Self.dngSpaceTitle) == nil {
                    spacePopup.addItem(withTitle: Self.dngSpaceTitle)
                }
                spacePopup.selectItem(withTitle: Self.dngSpaceTitle)
            } else {
                if let placeholder = spacePopup.item(withTitle: Self.dngSpaceTitle) {
                    spacePopup.removeItem(at: spacePopup.index(of: placeholder))
                }
                spacePopup.selectItem(withTitle: model.exportColorSpace.rawValue)
            }
        }
    }

    /// Output pane coordinate space: full-resolution dimensions regardless of
    /// preview bitmap resolution, so zoom/pan stays in sync with the input pane.
    var outputNominalSize: CGSize? {
        if phase.isRunning { return progressiveNominalSize }
        guard let result else { return nil }
        return CGSize(width: result.width, height: result.height)
    }

    var inputNominalSize: CGSize? { inputPixelSize }

    // MARK: - Inclusion

    /// Checkbox semantics: toggling a row that's part of a multi-selection
    /// applies the row's new state to every selected row. Frames of
    /// non-selected stacks toggle directly on their Stack.
    func setIncluded(_ url: URL, to value: Bool) {
        if !frames.contains(url),
           let owner = stacks.first(where: { $0.frames.contains(url) }) {
            objectWillChange.send()
            if value { owner.included.insert(url) } else { owner.included.remove(url) }
            return
        }
        let targets = selection.contains(url) && selection.count > 1 ? selection : [url]
        for target in targets {
            if value { included.insert(target) } else { included.remove(target) }
        }
    }

    /// Reads a frame's checkbox through the mirrors for the selected stack.
    func isIncluded(_ url: URL, in stack: Stack) -> Bool {
        stack.id == selectedStackID ? included.contains(url) : stack.included.contains(url)
    }

    func frameIssue(_ url: URL, in stack: Stack) -> String? {
        stack.id == selectedStackID ? frameIssues[url] : stack.frameIssues[url]
    }

    /// Frames of a stack as the UI should list them (mirrors for selected).
    func listedFrames(of stack: Stack) -> [URL] {
        stack.id == selectedStackID ? frames : stack.frames
    }

    func includeAll(_ value: Bool) {
        included = value ? Set(frames) : []
    }

    // MARK: - Input preview

    func selectionChanged() {
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
            let decoded: (image: NSImage, pixelSize: CGSize)? = {
                let buffer: ImageBuffer?
                if let alignedIndex {
                    let source = StackPipeline.makeSource(urls: alignedURLs,
                                                          transforms: transforms)
                    buffer = try? source.frame(at: alignedIndex)
                } else {
                    buffer = try? ImageFile.load(url: url)
                }
                guard let buffer,
                      let cg = try? ImageFile.cgImage8(from: buffer) else { return nil }
                return (NSImage(cgImage: cg, size: .zero),
                        CGSize(width: buffer.width, height: buffer.height))
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

    func fuse() {
        guard canFuse else { return }
        // Before any state changes: a cancelled preflight must leave the
        // current result and phase untouched.
        guard preflightDiskCache(urls: includedFrames) else { return }
        phase = .running
        stageText = "Starting…"
        stageFraction = 0
        progressive = nil
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
        let prompt = badFramePrompt ?? (batchMode ? { _ in true } : { lines in
            DispatchQueue.main.sync {
                let alert = NSAlert()
                alert.messageText = lines.count == 1
                    ? "1 frame looks bad" : "\(lines.count) frames look bad"
                alert.informativeText = lines.joined(separator: "\n")
                    + "\n\nExcluded frames stay in the Stack list with their checkbox cleared — re-check one to opt back in and re-fuse."
                alert.addButton(withTitle: "Exclude and Continue")
                alert.addButton(withTitle: "Keep All Frames")
                return alert.runModal() == .alertFirstButtonReturn
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
                    func nsImage(_ buffer: ImageBuffer?) -> NSImage? {
                        guard let buffer, let cg = try? ImageFile.cgImage8(from: buffer) else {
                            return nil
                        }
                        return NSImage(cgImage: cg, size: .zero)
                    }
                    let preview = nsImage(update.preview)
                    let nominal = update.previewFullWidth > 0
                        ? CGSize(width: update.previewFullWidth, height: update.previewFullHeight)
                        : nil
                    let source = nsImage(update.sourcePreview)
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
                        // One monotonic bar across the whole fuse: each stage
                        // owns a window of the overall span, and the max()
                        // keeps skipped stages (cache hits) from ever
                        // stepping the bar backward.
                        self.stageFraction = max(self.stageFraction,
                                                 Self.overallProgress(update.stage,
                                                                      update.fraction))
                        if let preview {
                            self.progressive = preview
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
                let resultCG = try ImageFile.cgImage8(from: output.image)
                let depthCG = try ImageFile.cgImage8(from: output.depthMap)
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
                    // Snapshot what this result was fused with (staleness
                    // tracking for the Fuse buttons).
                    self.fusedSettings = self.currentFuseSettings()
                    self.depthResult = output.depthMap
                    self.outputPreview = NSImage(cgImage: resultCG, size: .zero)
                    self.depthPreview = NSImage(cgImage: depthCG, size: .zero)
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Fuse failed"
        alert.informativeText = message
        alert.runModal()
    }

    /// Maps a per-stage fraction into the fuse's single progress span.
    /// Windows are rough stage-duration weights; registering and aligning
    /// share one span because the engine reports them on one 0…1 fraction.
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

    func beginNoiseFloorPreview() {
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

    func endNoiseFloorPreview() {
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
            let cg = try? ImageFile.cgImage8(from: image)
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
                self.noiseFloorPreview = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    func cancelFusion() {
        fusionCancellation?.cancel()
        stageText = "Cancelling…"
    }

    // MARK: - Retouching

    func enterRetouch() {
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
        outputMode = .result
        retouchMode = true
        // Sync the list to the session's current source immediately.
        if let session = retouch, session.urls.indices.contains(session.sourceIndex) {
            selection = [session.urls[session.sourceIndex]]
        }
    }

    func exitRetouch() {
        retouchMode = false
        // Reflect the edits in the normal output view (and export).
        if let session = retouch, session.hasEdits,
           let snapshot = session.makeSnapshotImage() {
            outputPreview = snapshot
        }
    }

    func resetRetouch() {
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
        let panel = NSSavePanel()
        let ext = exportFormat.fileExtension
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        // Name after the stack's folder — stable and meaningful, unlike
        // whichever frame happens to be first or selected.
        let base = (fuseURLs.first ?? frames.first)?
            .deletingLastPathComponent().lastPathComponent ?? "stacked"
        let suffix = outputMode == .depth ? " depth" : ""
        panel.nameFieldStringValue = "\(base)\(suffix).\(ext)"
        panel.accessoryView = ExportOptionsView(model: self, panel: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeExport(to: url)
    }

    /// Panel-free export: the write body of exportResult, honoring the
    /// current format/color-space/tone/output-mode state. Callable directly
    /// (UITestSupport's command channel).
    @discardableResult
    func writeExport(to url: URL) -> Bool {
        let baseImage = retouch?.hasEdits == true ? retouch?.working : (savedWorking ?? result)
        guard let image = outputMode == .depth ? depthResult : baseImage else { return false }
        do {
            // Tone bakes into display-referred formats only: DNG stays
            // linear for raw development, and the depth map is data.
            var toned = image
            if outputMode != .depth, exportFormat != .dng {
                ToneCurve.apply(settings: tone, to: &toned)
            }
            try ImageFile.save(toned, to: url, sourceFrame: fuseURLs.first,
                               colorSpace: exportColorSpace.cgColorSpace)
            if outputMode != .depth, exportFormat == .dng, !tone.isNeutral {
                // DNG stays linear; the tone rides along as embedded Camera
                // Raw XMP, which Lightroom/ACR read as develop settings.
                try XMPSidecar.embed(tone: tone, inDNGAt: url)
            }
            return true
        } catch {
            // Same rule as saveProjectPanel: a failed write doesn't
            // invalidate the fused result, so don't touch `phase`.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't export the image"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

}
