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
#if canImport(simd)
import simd
#endif

/// A retouching session over a fused result: a mutable working copy of the
/// output that brush strokes paint into, sourcing pixels from *aligned* input
/// frames. Undo is per-stroke via 256px tile snapshots. The fusion's
/// regularized depth plane doubles as an instant "sharpest frame here" oracle
/// for the space-key auto-pick.
@MainActor
public final class RetouchSession: ObservableObject {

    let urls: [URL]                 // the frame list the fusion ran on, in order
    let width: Int
    let height: Int
    public var nominalSize: CGSize { CGSize(width: width, height: height) }

    private static let log = Logger(subsystem: "org.hyperfocal", category: "retouch")

    @Published private(set) var sourceIndex: Int
    @Published public private(set) var sourceDisplay: PlatformImage? {
        didSet {
            // Tripwire for the low-res-pane bug family: with a *frame*
            // selected, the pane must never show fewer pixels than the
            // canvas (every legitimate writer is a full-res render; only
            // the PMax layer legitimately shows low-res build previews).
            // The 2026-07 stomp (stale-generation PMax previews over a
            // cache-hit frame) is fixed; if blur ever recurs, this names
            // the moment in `log show --predicate 'subsystem ==
            // "org.hyperfocal"'` instead of leaving another unreproducible
            // report.
            guard let image = sourceDisplay, sourceIndex < urls.count,
                  image.width > 0, image.width < width / 2 else { return }
            Self.log.fault("""
                retouch source pane got a \(image.width)x\(image.height) image \
                for a \(self.width)x\(self.height) frame (index \(self.sourceIndex))
                """)
        }
    }
    @Published public private(set) var sourceLoading = false
    @Published public private(set) var sourceError: String?
    /// Preparing-status for the loading overlay ("Preparing the PMax result… 40%").
    @Published public private(set) var sourceStatus: String?
    /// True while `sourceDisplay` is a data visualization (a DMap secondary's
    /// forming depth map) rather than image pixels — the pane skips tone for it,
    /// same as the result panel's depth view.
    @Published public private(set) var sourceShowsData = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published public private(set) var hasEdits = false
    @Published public var cursor: CGPoint?          // hover location, image coords
    @Published public var brushRadius: Double = 32  // image px
    /// The one range every brush-size control shares (the slider, ⌥-scroll,
    /// and the [ ] keys all move `brushRadius`) — a single constant so they
    /// can't drift apart again.
    static let brushRadiusRange: ClosedRange<Double> = 1...800
    @Published public var brushSoftness: Double = 0.2
    /// True from a mouse-down that found no source pixels (still loading)
    /// until its mouse-up: that drag never paints, so the brush circle stays
    /// hidden for its whole duration even if the load lands mid-drag.
    @Published private(set) var deadDrag = false

    /// Whether a stroke would actually paint right now. The panes only show
    /// the brush circle when it's honest — a circle over a still-loading
    /// source (or during a dead drag) promises painting that can't happen.
    public var canPaint: Bool { sourceFloat != nil && !deadDrag }

    /// Change-notification seam for non-Combine clients (the C-ABI
    /// bridge) — the session is its own ObservableObject, so its
    /// published state (source loading, canPaint, brush, edits) never
    /// reaches AppModel.objectWillChange; clients that only observe the
    /// model would show stale retouch UI forever. Same contract as
    /// AppModel.addChangeObserver.
    public func addChangeObserver(_ observer: @escaping () -> Void) -> AnyObject {
        objectWillChange.sink { _ in observer() }
    }

    private(set) var working: ImageBuffer
    /// The depth plane, co-painted by strokes: painting from frame N writes
    /// N's index under the brush (those ARE the pixels being copied), the
    /// eraser restores the session-start depth, and the PMax layer leaves
    /// depth alone (its pixels have no single depth). This is what makes
    /// depth artifacts in the rocking animation fixable by retouching.
    private(set) var workingDepth: [Float]
    /// Depth as the session started (eraser source and Revert All target).
    private let originalDepth: [Float]
    /// Set when a stroke, undo, redo, or revert may have changed
    /// `workingDepth`; the model folds the plane back into `resultDepth`
    /// (and re-renders the depth visualizations) then clears this.
    private(set) var depthDirty = false
    func markDepthMerged() { depthDirty = false }
    private let sharpness: FrameSharpness?
    private var stackSource: StackSource

    private var displayPixels: [UInt8]
    /// Live grayscale visualization of `workingDepth` (1 byte/px), same
    /// mapping as DMapFusion.depthImage so toggling between the fusion's
    /// static depth pane and this live one shows identical shades.
    private var depthDisplayPixels: [UInt8]
    private let depthDisplayScale: Float
    /// The canvas view registers here; strokes report the image-space rect they
    /// touched so only that region repaints (NOT a full-frame image rebuild —
    /// that was unusably slow at 45 MP).
    public var onDisplayDirty: ((CGRect) -> Void)?
    /// Fired when the source frame changes (arrows / space / programmatic), so
    /// the app can keep the Stack list selection in sync.
    var onSourceChanged: ((Int) -> Void)?
    /// Fired whenever the working pixels change (stroke, undo, redo, revert) —
    /// the app tracks unsaved work with it.
    var onEdited: (() -> Void)?
    /// Fired when the user selects the other algorithm's brush source and no
    /// image exists yet — the model's cue to start a *deferred* background
    /// pass (on memory-tight machines that pass doesn't run eagerly at fuse
    /// completion). Harmless when the pass is already running: the model
    /// ignores the cue and `provideOtherResult` resolves the pane as usual.
    var onOtherSourceNeeded: (() -> Void)?
    /// Fired when `endStroke` actually records a stroke (empty drags don't).
    /// The model mirrors each recorded stroke as a `.stroke` marker in its
    /// edit history, so ⌘Z walks strokes and tone/crop/inclusion edits as
    /// one timeline — the marker count and `undoStack.count` must stay in
    /// lockstep (see AppModel's undo section).
    var onStrokeRecorded: (() -> Void)?
    /// Fired when the stroke cap evicts the oldest snapshot — the model
    /// drops its oldest `.stroke` marker to keep the counts in step.
    var onOldestStrokeEvicted: (() -> Void)?

    // Aligned source frames: float pixels for painting, CGImage for the pane.
    // Published because `canPaint` derives from it (the result layer is
    // paintable while its pane preview still renders, so `sourceLoading`
    // alone can't drive the brush circle).
    @Published private(set) var sourceFloat: ImageBuffer?
    private var sourceCache: [Int: (buffer: ImageBuffer, image: PlatformImage)] = [:]
    private var sourceCacheOrder: [Int] = []
    private var sourceLoadGeneration = 0

    // The two algorithm results as brush sources — DMap and PMax, peers. The
    // one matching the fused result (`baseMethod`) is the in-memory base and
    // doubles as the eraser (paint the pristine fusion back exactly where a
    // stroke overreached); the other is the model's background pass, handed
    // over by `provideOtherResult` (or, for PMax when DMap is the base, built
    // on demand as a fallback). PMax helps where structures at different depths
    // overlap and a single depth per pixel is wrong.
    let baseMethod: FusionMethod
    /// The algorithm whose result is NOT the base — the alternate brush source.
    var otherMethod: FusionMethod { baseMethod == .dmap ? .pmax : .dmap }
    var pmaxIndex: Int { urls.count }
    var isPMaxSource: Bool { sourceIndex == pmaxIndex }
    var dmapIndex: Int { urls.count + 1 }
    var isDMapSource: Bool { sourceIndex == dmapIndex }
    /// True when the selected source is the fused base — instant, and it acts
    /// as the eraser (restores original pixels + the session-start depth).
    var isBaseSource: Bool {
        (isPMaxSource && baseMethod == .pmax) || (isDMapSource && baseMethod == .dmap)
    }
    /// The non-base algorithm's image, from the model's background pass. The
    /// base itself is always `originalResult`.
    private var otherImage: (buffer: ImageBuffer, image: PlatformImage)?
    private var lastFrameSourceIndex = 0
    private let originalResult: ImageBuffer
    private var resultImageCache: PlatformImage?

    public var sourceName: String {
        if isPMaxSource { return localizedString("PMax Result", comment: "") }
        if isDMapSource { return localizedString("DMap Result", comment: "") }
        return String(format: localizedString("%@ (aligned)", comment: ""),
                      urls[sourceIndex].lastPathComponent)
    }

    /// The three kinds of brush source for the "Retouch from" radio group. The
    /// two algorithm results are peers; whichever matches the fused result
    /// doubles as the eraser.
    public enum SourceKind: Hashable {
        case frame   // an aligned source slice (↑/↓ picks which)
        case dmap    // the DMap result image
        case pmax    // the PMax result image
    }

    public var sourceKind: SourceKind {
        isPMaxSource ? .pmax : isDMapSource ? .dmap : .frame
    }

    public func selectKind(_ kind: SourceKind) {
        switch kind {
        case .frame: selectSource(lastFrameSourceIndex)
        case .dmap: selectSource(dmapIndex)
        case .pmax: selectSource(pmaxIndex)
        }
    }


    // Tile-based per-stroke undo. Snapshots carry the depth plane alongside
    // the pixels — strokes co-paint depth, so undo must restore both.
    private struct TileSnapshot {
        // Same f16 storage as `working.pixels` — tile undo copies bytes, it
        // never does arithmetic on them, so the stroke history halves too.
        var pixels: [Float16]
        var depth: [Float]
    }
    private static let tileSize = 256
    private static let maxUndoStrokes = 20
    /// Byte ceiling on the retained stroke snapshots, alongside the count
    /// cap. Twenty strokes is a fine history for small dabs, but a snapshot
    /// costs 12 bytes per covered pixel (f16 RGBA + Float depth), so broad
    /// strokes on a large canvas pin hundreds of MB each — a 36 MP session
    /// idles at ~4.2 GB, and twenty near-full-canvas snapshots would add
    /// ~9 GB on top, which is compressor/swap territory on smaller machines
    /// long before the count cap helps. An eighth of physical RAM (capped
    /// at 2 GiB) keeps deep history for normal brushes and sheds
    /// oldest-first under huge ones; the newest stroke always survives,
    /// whatever its size, so ⌘Z never goes dead right after painting.
    static let maxUndoBytes = min(Int64(2) << 30,
                                  Int64(ProcessInfo.processInfo.physicalMemory / 8))
    /// Probe seam: a RAM-relative default isn't assertable on an arbitrary
    /// machine, so the byte-budget check pins its own ceiling.
    var undoByteBudgetOverride: Int64?
    /// Snapshots currently held for ⌘Z, in bytes (probe-visible).
    var undoStackBytes: Int64 { undoStack.reduce(0) { $0 + Self.bytes(of: $1) } }
    private static func bytes(of stroke: [Int: TileSnapshot]) -> Int64 {
        stroke.values.reduce(0) {
            $0 + Int64($1.pixels.count * MemoryLayout<Float16>.stride
                       + $1.depth.count * MemoryLayout<Float>.stride)
        }
    }
    private var currentStrokeTiles: [Int: TileSnapshot] = [:]
    private var undoStack: [[Int: TileSnapshot]] = []
    private var redoStack: [[Int: TileSnapshot]] = []
    private var strokeActive = false

    /// `source` must be the same StackSource configuration the fusion used
    /// (including any common-coverage crop) so aligned slices match the
    /// result. `restoredWorking` re-installs retouch edits from a saved
    /// session.
    init(result: ImageBuffer, method: FusionMethod, depth: [Float],
         sharpness: FrameSharpness?, source: StackSource,
         restoredWorking: ImageBuffer? = nil, initialSourceIndex: Int? = nil) {
        self.urls = source.urls
        self.baseMethod = method
        self.width = result.width
        self.height = result.height
        self.originalResult = result
        if let restoredWorking, restoredWorking.width == result.width,
           restoredWorking.height == result.height {
            self.working = restoredWorking
            self.hasEdits = true
        } else {
            self.working = result
        }
        // A PMax primary has no depth map; retouch still works (frames +
        // eraser), so stand in a flat plane to keep the depth-plane machinery
        // (co-paint, undo snapshots, live view) well-defined. The model never
        // folds this back — `mergeRetouchDepth` runs only for a DMap primary.
        let depthPlane = depth.isEmpty
            ? [Float](repeating: 0, count: result.width * result.height) : depth
        self.workingDepth = depthPlane
        self.originalDepth = depthPlane
        // Same normalization as DMapFusion.depthImage(frameCount:) so the
        // live view matches the fusion's static depth render shade-for-shade.
        self.depthDisplayScale = 1 / Float(max(source.count, 2) - 1)
        self.sharpness = sharpness
        self.stackSource = source
        self.sourceIndex = initialSourceIndex.map { min(max($0, 0), source.count - 1) }
            ?? source.count / 2

        var pixels = [UInt8](repeating: 0, count: result.width * result.height * 4)
        Self.convertToBytes(from: working, into: &pixels,
                            rect: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        self.displayPixels = pixels
        var depthBytes = [UInt8](repeating: 0, count: result.width * result.height)
        Self.convertDepthToBytes(from: depthPlane, scale: depthDisplayScale,
                                 into: &depthBytes, width: result.width,
                                 rows: 0..<result.height)
        self.depthDisplayPixels = depthBytes

        selectSource(sourceIndex)
    }

    // MARK: - Display access

    /// Bumped on every display-plane mutation (strokes, undo/redo tile
    /// restores, revert); the portable depth-view cache keys on it.
    private var displayGeneration = 0
    #if !canImport(CoreGraphics)
    private var depthDisplayCache: (generation: Int, image: PlatformImage)?
    #endif

    /// Zero-copy image over the live display bytes, valid within `body`
    /// only. Off Apple the wrapper class shares the byte array (CoW) for
    /// the call's duration — the portable spelling of the same contract;
    /// nothing retains the wrapper past the call, so the session's later
    /// writes never trigger a copy. (Serving nil here blacked out the Qt
    /// pane on the first stroke: tiles refetch through this accessor once
    /// the dirty epoch bumps.)
    public func withDisplayCGImage<R>(_ body: (PlatformImage?) -> R) -> R {
        #if !canImport(CoreGraphics)
        return body(PlatformImage(width: width, height: height, rgba: displayPixels))
        #else
        let w = width, h = height
        return displayPixels.withUnsafeMutableBytes { raw -> R in
            guard let base = raw.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base, size: raw.count,
                                                releaseData: { _, _, _ in }) else {
                return body(nil)
            }
            let space = ImageFile.workingSpace
            guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) else {
                return body(nil)
            }
            return body(cg)
        }
        #endif
    }

    /// Zero-copy grayscale image over the live depth-view bytes, valid
    /// within `body` only. Off Apple, PlatformImage is RGBA-only, so the
    /// gray plane expands once per display generation into a cached
    /// wrapper — per-tile expansion would redo the full frame for every
    /// tile the pane fetches.
    public func withDepthDisplayCGImage<R>(_ body: (PlatformImage?) -> R) -> R {
        #if !canImport(CoreGraphics)
        if depthDisplayCache?.generation != displayGeneration {
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            depthDisplayPixels.withUnsafeBufferPointer { src in
                rgba.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<(width * height) {
                        let v = src[i]
                        dst[i * 4] = v
                        dst[i * 4 + 1] = v
                        dst[i * 4 + 2] = v
                    }
                }
            }
            depthDisplayCache = (displayGeneration,
                                 PlatformImage(width: width, height: height, rgba: rgba))
        }
        return body(depthDisplayCache!.image)
        #else
        let w = width, h = height
        return depthDisplayPixels.withUnsafeMutableBytes { raw -> R in
            guard let base = raw.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base, size: raw.count,
                                                releaseData: { _, _, _ in }) else {
                return body(nil)
            }
            guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                   bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) else {
                return body(nil)
            }
            return body(cg)
        }
        #endif
    }

    /// One-off full snapshot (used when leaving retouch mode).
    func makeSnapshotImage() -> PlatformImage? {
        Self.makeImage(from: displayPixels, width: width, height: height)
    }

    public func adjustBrushRadius(by factor: Double) {
        brushRadius = min(max(brushRadius * factor, Self.brushRadiusRange.lowerBound),
                          Self.brushRadiusRange.upperBound)
    }

    // MARK: - Source slice management

    /// Late arrival of a warped-frame spill for this session's frame list —
    /// the PMax-primary case, where the spill is produced by the background
    /// DMap pass *after* the session was built. A complete cache supersedes
    /// the lazily-filled partial one the session may have started with; an
    /// already-complete cache is never replaced. Frame loads from here on
    /// stream off SSD instead of re-decoding (`StackSource.warped`); loads
    /// already in flight carry the pre-adoption source copy and just decode.
    /// Mismatched caches are rejected by `StackSource.frame(at:)` itself.
    func adoptWarpedFrames(_ cache: WarpedFrameCache) {
        if let existing = stackSource.warped, existing.isComplete { return }
        stackSource.warped = cache
    }

    /// Whether frame-source loads consult a warped-frame cache (fuse-retained
    /// or lazily filling — vs decoding every switch from the original files).
    /// Probe-visible: retouch-probe asserts the cache reaches the session.
    var sourceStreamsFromSpill: Bool { stackSource.warped != nil }
    /// Probe taps: cache occupancy, and whether it is the complete
    /// fuse-retained spill rather than a lazily-filling partial one.
    var sourceSpillPopulation: Int { stackSource.warped?.populatedCount ?? 0 }
    var sourceSpillComplete: Bool { stackSource.warped?.isComplete ?? false }

    func selectSource(_ index: Int) {
        sourceShowsData = false  // a fresh selection starts as image pixels
        // pmaxIndex and dmapIndex are valid selections (the two algorithm-result
        // layers); everything else clamps to the frame list. Cycling off a
        // layer lands on a frame.
        let clamped = index == pmaxIndex || index == dmapIndex
            ? index : min(max(index, 0), urls.count - 1)
        if clamped == pmaxIndex {
            selectPMaxLayer()
            return
        }
        if clamped == dmapIndex {
            selectDMapLayer()
            return
        }
        lastFrameSourceIndex = clamped
        // Navigating away no longer cancels a building PMax layer — it keeps
        // building in the background and caches, so returning to it is instant.
        let changed = clamped != sourceIndex
        sourceIndex = clamped
        if changed { onSourceChanged?(clamped) }
        // Supersede in-flight async work BEFORE the cache check — a cache
        // hit must bump the generation too, or stragglers from an abandoned
        // load/build still pass the staleness guards below (a building PMax
        // layer kept stomping a cache-hit frame's pane with its low-res
        // progress previews, then nulled the paint source on cancellation:
        // blurry source pane over a sharp brush). The generation bump is what
        // keeps the still-running build from touching this pane.
        sourceLoadGeneration += 1
        if let cached = sourceCache[clamped] {
            // LRU refresh: a hit keeps the frame hot, or FIFO eviction could
            // drop the frame being painted right after a neighbor prefetch
            // lands (the tighter 2-slot cap made that a real race — the
            // supersede probe caught a toggle-back losing its cache hit).
            if let pos = sourceCacheOrder.firstIndex(of: clamped) {
                sourceCacheOrder.remove(at: pos)
                sourceCacheOrder.append(clamped)
            }
            sourceFloat = cached.buffer
            sourceDisplay = cached.image
            sourceLoading = false
            sourceStatus = nil
            sourceError = nil
            prefetchNeighbors(of: clamped)
            return
        }
        sourceFloat = nil
        sourceDisplay = nil
        sourceLoading = true
        sourceStatus = nil
        let generation = sourceLoadGeneration
        let (source, localIndex) = (stackSource, clamped)
        let url = urls[clamped]
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded: (buffer: ImageBuffer, image: PlatformImage)?
            do {
                loaded = try Self.loadAligned(index: localIndex, from: source)
            } catch {
                loaded = nil
                FileHandle.standardError.write(
                    Data("retouch: source load failed idx=\(clamped): \(error)\n".utf8))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let loaded {
                    self.cacheSource(loaded, at: clamped)
                }
                // Never strand the spinner: even on failure or a superseded
                // request, the *current* request must resolve the UI state.
                guard generation == self.sourceLoadGeneration else { return }
                self.sourceFloat = loaded?.buffer
                self.sourceDisplay = loaded?.image
                self.sourceLoading = false
                self.sourceError = loaded == nil
                    ? (FileManager.default.fileExists(atPath: url.path)
                        ? String(format: localizedString("Couldn't load %@", comment: ""),
                                 url.lastPathComponent)
                        : String(format: localizedString("%@ is missing", comment: ""),
                                 url.lastPathComponent))
                    : nil
                if loaded != nil {
                    self.prefetchNeighbors(of: clamped)
                }
            }
        }
    }


    public func cycleSource(by delta: Int) {
        if sourceIndex >= urls.count {
            selectSource(lastFrameSourceIndex)  // arrows leave the blend/eraser layers
        } else {
            selectSource(sourceIndex + delta)
        }
    }

    public func togglePMaxLayer() {
        selectSource(isPMaxSource ? lastFrameSourceIndex : pmaxIndex)
    }

    public func toggleDMapLayer() {
        selectSource(isDMapSource ? lastFrameSourceIndex : dmapIndex)
    }

    /// The result/base layer — the eraser, whichever algorithm fused it.
    /// Distinct from `toggleDMapLayer` since PMax primaries: "result" used
    /// to mean DMap because DMap was the only primary; now R follows the
    /// base and D pins the DMap layer specifically.
    public func toggleResultLayer() {
        selectSource(isBaseSource ? lastFrameSourceIndex
                                  : (baseMethod == .pmax ? pmaxIndex : dmapIndex))
    }

    /// Hand over the non-base algorithm's image — the model's background pass —
    /// so selecting it as a brush source is instant (no re-fuse). No-op once a
    /// layer is cached. If the user is waiting on it, this resolves the pane.
    public func provideOtherResult(_ buffer: ImageBuffer) {
        guard otherImage == nil, let image = try? Preview.image(from: buffer) else { return }
        finishOtherSource(buffer, image)
    }

    private var otherIndex: Int { baseMethod == .pmax ? dmapIndex : pmaxIndex }

    /// The single "a source is being prepared" label — one template for both
    /// algorithms so the DMap and PMax wording can never drift apart.
    private func preparingStatus(_ fraction: Double?) -> String {
        let base = String(format: localizedString("Preparing the %@ result…", comment: ""),
                          otherMethod.displayName)
        guard let fraction else { return base }
        return base + String(format: " %lld%%", Int((fraction * 100).rounded()))
    }

    /// Forming-preview + progress for the alternate source, from the model's
    /// background pass. Same pane treatment as the result panel: the preview
    /// fills in as it renders. No-op unless the user is waiting on this source.
    public func otherSourceProgress(fraction: Double, preview: PlatformImage?, isData: Bool) {
        guard sourceIndex == otherIndex, sourceLoading else { return }
        sourceStatus = preparingStatus(fraction)
        if let preview {
            sourceDisplay = preview
            sourceShowsData = isData
        }
    }

    /// The alternate source finished (the model's background pass). Caches it
    /// and, if the user is waiting on it, resolves the pane.
    private func finishOtherSource(_ buffer: ImageBuffer, _ image: PlatformImage) {
        if otherImage == nil { otherImage = (buffer, image) }
        guard sourceIndex == otherIndex, sourceLoading else { return }
        sourceLoadGeneration += 1  // supersede any stale in-flight source load
        sourceFloat = buffer
        sourceDisplay = image
        sourceShowsData = false
        sourceLoading = false
        sourceStatus = nil
        sourceError = nil
    }

    private func selectPMaxLayer() {
        let changed = sourceIndex != pmaxIndex
        sourceIndex = pmaxIndex
        if changed { onSourceChanged?(pmaxIndex) }
        sourceLoadGeneration += 1
        if baseMethod == .pmax { useBaseSource() } else { useOtherSource() }
    }

    private func selectDMapLayer() {
        let changed = sourceIndex != dmapIndex
        sourceIndex = dmapIndex
        if changed { onSourceChanged?(dmapIndex) }
        sourceLoadGeneration += 1
        if baseMethod == .dmap { useBaseSource() } else { useOtherSource() }
    }

    /// One memory gate for the whole app (`AppModel.eagerCompletionFits`): on
    /// machines that can't afford spare full-resolution planes, the
    /// frame-source cache is dropped whenever a result layer is selected —
    /// those slices are cold while a result layer paints, and two 45 MP
    /// entries are ~1.1 GB that a deferred secondary generation (which the
    /// same selection can trigger) needs back. Switching back to a frame
    /// source re-decodes through the normal loading flow.
    private lazy var frugalMemory =
        !AppModel.eagerCompletionFits(canvasPixels: width * height)

    private func trimSourceCacheIfFrugal() {
        guard frugalMemory else { return }
        sourceCache.removeAll()
        sourceCacheOrder.removeAll()
    }

    /// The fused base as a brush source (the eraser): instant — its buffer is
    /// retained anyway; only the 8-bit pane preview is rendered, once.
    private func useBaseSource() {
        trimSourceCacheIfFrugal()
        sourceFloat = originalResult
        sourceStatus = nil
        sourceError = nil
        if let cached = resultImageCache {
            sourceDisplay = cached
            sourceLoading = false
            return
        }
        sourceDisplay = nil
        sourceLoading = true
        let generation = sourceLoadGeneration
        let buffer = originalResult
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = try? Preview.image(from: buffer)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let image { self.resultImageCache = image }
                guard generation == self.sourceLoadGeneration else { return }
                self.sourceDisplay = image
                self.sourceLoading = false
                self.sourceError = image == nil ? "Couldn't render the result layer" : nil
            }
        }
    }

    /// The non-base algorithm's image. Uses it if already cached; otherwise
    /// enters the shared "Preparing the <algorithm> result…" state and waits for
    /// the model's background pass, which feeds the forming preview via
    /// `otherSourceProgress` and completes via `provideOtherResult`.
    private func useOtherSource() {
        trimSourceCacheIfFrugal()
        if let other = otherImage {
            sourceFloat = other.buffer
            sourceDisplay = other.image
            sourceLoading = false
            sourceStatus = nil
            sourceError = nil
            return
        }
        sourceFloat = nil
        sourceDisplay = nil
        sourceLoading = true
        sourceError = nil
        sourceStatus = preparingStatus(nil)
        onOtherSourceNeeded?()
    }

    /// True while the selected brush source is the other algorithm's image and
    /// that image hasn't arrived. The model checks this when it defers the
    /// background pass: a restored session can come up already waiting (its
    /// saved source index), having fired `onOtherSourceNeeded` before the
    /// model had anything to start.
    var isWaitingForOtherSource: Bool {
        sourceIndex == otherIndex && otherImage == nil
    }

    /// Space key: measure the brush region's sharpness in *every* frame and jump
    /// to the sharpest — the raw pre-regularization measurement, independent of
    /// what the fusion decided (retouching happens exactly where that decision
    /// was wrong, so consulting it would be circular).
    public func autoPickSource(at point: CGPoint) {
        if let sharpness {
            let scores = sharpness.regionScores(centerX: point.x, centerY: point.y,
                                                radius: brushRadius)
            if let best = scores.indices.max(by: { scores[$0] < scores[$1] }),
               scores[best] > 0 {
                selectSource(best)
                return
            }
        }
        // Fallback (no retained sharpness): majority vote of the depth plane.
        let r = brushRadius
        let step = max(1, Int(r / 24))
        var votes = [Int: Int]()
        let x0 = max(0, Int(point.x - r)), x1 = min(width - 1, Int(point.x + r))
        let y0 = max(0, Int(point.y - r)), y1 = min(height - 1, Int(point.y + r))
        guard x0 <= x1, y0 <= y1 else { return }
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let dx = Double(x) - point.x, dy = Double(y) - point.y
                if dx * dx + dy * dy <= r * r {
                    let index = Int(workingDepth[y * width + x].rounded())
                    votes[index, default: 0] += 1
                }
                x += step
            }
            y += step
        }
        if let winner = votes.max(by: { $0.value < $1.value })?.key {
            selectSource(winner)
        }
    }

    private func cacheSource(_ loaded: (buffer: ImageBuffer, image: PlatformImage), at index: Int) {
        guard sourceCache[index] == nil else { return }
        sourceCache[index] = loaded
        sourceCacheOrder.append(index)
        MemoryFootprint.mark("retouch source cached (\(sourceCacheOrder.count) held)")
        // Keep 2 full-res float frames at most (~1.7 GB at 45 MP with their
        // display images — the cache was the largest single entry in the
        // fused-idle memory ledger at 3). Current + one neighbor still makes
        // directional frame-cycling instant; a third slot mostly held the
        // trailing neighbor nobody returns to. Never evict the CURRENT
        // source: with LRU order (refreshed on hit) the oldest non-current
        // entry is the right victim.
        while sourceCacheOrder.count > 2 {
            guard let victim = sourceCacheOrder.firstIndex(where: { $0 != sourceIndex }) else { break }
            sourceCache.removeValue(forKey: sourceCacheOrder.remove(at: victim))
        }
    }

    private func prefetchNeighbors(of index: Int) {
        for neighbor in [index + 1, index - 1]
        where urls.indices.contains(neighbor) && sourceCache[neighbor] == nil {
            let (source, localIndex) = (stackSource, neighbor)
            Task.detached(priority: .utility) { [weak self] in
                guard let loaded = try? Self.loadAligned(index: localIndex, from: source) else {
                    return  // prefetch is opportunistic; selection reports errors
                }
                await MainActor.run { [weak self] in
                    self?.cacheSource(loaded, at: neighbor)
                }
            }
            break  // one prefetch at a time; the next follows on selection
        }
    }

    nonisolated private static func loadAligned(index: Int, from source: StackSource)
        throws -> (buffer: ImageBuffer, image: PlatformImage) {
        let buffer = try source.frame(at: index)
        return (buffer, try Preview.image(from: buffer))
    }

    // MARK: - Painting

    /// Path distance traveled since the last stamp, carried across
    /// continueStroke calls: stamp density must be set by `spacing`, not by
    /// mouse-event granularity. (Stamping at least once per event made a
    /// max-radius drag do the full O(r²) blend for every few pixels of
    /// travel — the large-brush lag, in both shells.)
    private var strokeCarry: Double = 0

    /// Called when the user actually enters retouch mode: force-unique the
    /// mutable planes so the first brush stamp pays no copy-on-write —
    /// `working` shares storage with the model's result (and workingDepth
    /// with originalDepth) until the first mutating access, which put
    /// ~860 MB of copies at 45 MP on the first stroke's critical path.
    /// Deliberately NOT done at session build: the pre-warmed idle session
    /// then keeps sharing the model's buffers and costs no extra memory
    /// until retouch is actually entered.
    func prepareForPainting() {
        working.pixels.withUnsafeMutableBufferPointer { _ in }
        workingDepth.withUnsafeMutableBufferPointer { _ in }
    }

    public func beginStroke(at point: CGPoint) {
        guard sourceFloat != nil else {
            deadDrag = true
            return
        }
        strokeActive = true
        strokeCarry = 0
        currentStrokeTiles = [:]
        stamp(at: point)
    }

    public func continueStroke(from p0: CGPoint, to p1: CGPoint) {
        guard strokeActive, sourceFloat != nil else { return }
        let length = hypot(p1.x - p0.x, p1.y - p0.y)
        guard length > 0 else { return }
        let spacing = max(1, brushRadius / 3)
        var next = spacing - strokeCarry  // distance along this segment to the next stamp
        guard next <= length else {
            strokeCarry += length
            return
        }
        while next <= length {
            let t = next / length
            stamp(at: CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
            next += spacing
        }
        strokeCarry = length - (next - spacing)
    }

    public func endStroke() {
        deadDrag = false
        guard strokeActive else { return }
        strokeActive = false
        if !currentStrokeTiles.isEmpty {
            undoStack.append(currentStrokeTiles)
            // Two caps, one eviction loop: count (deep histories of small
            // dabs) and bytes (few huge strokes). Each eviction notifies the
            // model so its oldest .stroke marker drops in lockstep.
            let budget = undoByteBudgetOverride ?? Self.maxUndoBytes
            var bytes = undoStackBytes
            while undoStack.count > Self.maxUndoStrokes
                    || (bytes > budget && undoStack.count > 1) {
                bytes -= Self.bytes(of: undoStack.removeFirst())
                onOldestStrokeEvicted?()
            }
            redoStack = []
            canUndo = true
            canRedo = false
            hasEdits = true
            onEdited?()
            onStrokeRecorded?()
        }
        currentStrokeTiles = [:]
    }

    func undo() {
        guard let stroke = undoStack.popLast() else { return }
        // Capture the post-stroke pixels of the same tiles so redo can replay.
        redoStack.append(captureTiles(stroke.keys))
        for (tileIndex, snapshot) in stroke {
            restoreTile(tileIndex, snapshot: snapshot)
        }
        canUndo = !undoStack.isEmpty
        canRedo = true
        depthDirty = true
        onEdited?()
    }

    func redo() {
        guard let stroke = redoStack.popLast() else { return }
        undoStack.append(captureTiles(stroke.keys))
        for (tileIndex, snapshot) in stroke {
            restoreTile(tileIndex, snapshot: snapshot)
        }
        canRedo = !redoStack.isEmpty
        canUndo = true
        hasEdits = true
        depthDirty = true
        onEdited?()
    }

    /// A new *model* edit (tone drag, inclusion toggle) starts a fresh
    /// branch of the shared timeline: it clears the model's redo history,
    /// and this clears the stroke half so the two stay one stack.
    func clearRedo() {
        redoStack = []
        canRedo = false
    }

    /// The model's edit-history cap evicted a `.stroke` marker — shed the
    /// matching (oldest) snapshot so marker and stroke counts stay equal.
    /// Silent: re-notifying the model would drop a second marker.
    func dropOldestUndo() {
        guard !undoStack.isEmpty else { return }
        undoStack.removeFirst()
        canUndo = !undoStack.isEmpty
    }

    private func captureTiles<S: Sequence>(_ tiles: S) -> [Int: TileSnapshot]
        where S.Element == Int {
        var snapshot = [Int: TileSnapshot]()
        for tileIndex in tiles {
            snapshot[tileIndex] = copyTile(tx: tileIndex % tilesAcross,
                                           ty: tileIndex / tilesAcross)
        }
        return snapshot
    }

    /// Set when Revert All discards real edits: the output pane may still
    /// be showing a snapshot of them (exit with edits, revert on a later
    /// visit), so the model must re-present the reverted pixels even
    /// though `hasEdits` is false again. Cleared once a snapshot goes out.
    private(set) var didRevert = false
    func markRevertPresented() { didRevert = false }

    func resetAll(to original: ImageBuffer) {
        if hasEdits { didRevert = true }
        working = original
        workingDepth = originalDepth
        undoStack = []
        redoStack = []
        currentStrokeTiles = [:]
        canUndo = false
        canRedo = false
        hasEdits = false
        depthDirty = true
        Self.convertToBytes(from: working, into: &displayPixels,
                            rect: CGRect(x: 0, y: 0, width: width, height: height))
        Self.convertDepthToBytes(from: workingDepth, scale: depthDisplayScale,
                                 into: &depthDisplayPixels, width: width,
                                 rows: 0..<height)
        displayGeneration &+= 1
        onDisplayDirty?(CGRect(x: 0, y: 0, width: width, height: height))
        onEdited?()
    }

    private func stamp(at center: CGPoint) {
        guard let src = sourceFloat else { return }
        let r = brushRadius
        let inner = r * (1 - brushSoftness)
        let x0 = max(0, Int(center.x - r)), x1 = min(width - 1, Int(center.x + r))
        let y0 = max(0, Int(center.y - r)), y1 = min(height - 1, Int(center.y + r))
        guard x0 <= x1, y0 <= y1 else { return }

        snapshotTiles(x0: x0, y0: y0, x1: x1, y1: y1)

        // The stroke's depth: a frame paints its own index (that IS the depth
        // of the pixels being copied); the base result is the eraser and paints
        // the session-start depth back; the OTHER algorithm's result — whose
        // pixels have no matching single depth — leaves the plane alone.
        let isAlgorithmSource = isPMaxSource || isDMapSource
        let paintsDepth = !isAlgorithmSource || isBaseSource
        let eraseDepth = isBaseSource
        let frameDepth = Float(min(sourceIndex, urls.count - 1))
        // The pixel loop is RetouchPaint's (the Kit is -O in every
        // configuration; this loop at the model layer's Debug -Onone ran
        // ~30x slower and coalesced drag events into polygon strokes).
        working.pixels.withUnsafeMutableBufferPointer { dst in
            src.pixels.withUnsafeBufferPointer { s in
                displayPixels.withUnsafeMutableBufferPointer { bytes in
                    workingDepth.withUnsafeMutableBufferPointer { wd in
                        originalDepth.withUnsafeBufferPointer { od in
                            depthDisplayPixels.withUnsafeMutableBufferPointer { dbytes in
                                RetouchPaint.stamp(
                                    working: dst.baseAddress!,
                                    source: s.baseAddress!,
                                    display: bytes.baseAddress!,
                                    workingDepth: wd.baseAddress!,
                                    originalDepth: od.baseAddress!,
                                    depthDisplay: dbytes.baseAddress!,
                                    width: width,
                                    centerX: center.x, centerY: center.y,
                                    radius: r, inner: inner,
                                    x0: x0, y0: y0, x1: x1, y1: y1,
                                    paintsDepth: paintsDepth,
                                    eraseDepth: eraseDepth,
                                    frameDepth: frameDepth,
                                    depthDisplayScale: depthDisplayScale)
                            }
                        }
                    }
                }
            }
        }
        if paintsDepth { depthDirty = true }
        displayGeneration &+= 1
        onDisplayDirty?(CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
    }

    // MARK: - Undo tiles

    private var tilesAcross: Int { (width + Self.tileSize - 1) / Self.tileSize }

    private func snapshotTiles(x0: Int, y0: Int, x1: Int, y1: Int) {
        let ts = Self.tileSize
        for ty in (y0 / ts)...(y1 / ts) {
            for tx in (x0 / ts)...(x1 / ts) {
                let tileIndex = ty * tilesAcross + tx
                guard currentStrokeTiles[tileIndex] == nil else { continue }
                currentStrokeTiles[tileIndex] = copyTile(tx: tx, ty: ty)
            }
        }
    }

    private func tileRect(tx: Int, ty: Int) -> (x0: Int, y0: Int, w: Int, h: Int) {
        let ts = Self.tileSize
        let x0 = tx * ts, y0 = ty * ts
        return (x0, y0, min(ts, width - x0), min(ts, height - y0))
    }

    private func copyTile(tx: Int, ty: Int) -> TileSnapshot {
        let r = tileRect(tx: tx, ty: ty)
        var out = [Float16](repeating: 0, count: r.w * r.h * 4)
        var outDepth = [Float](repeating: 0, count: r.w * r.h)
        working.pixels.withUnsafeBufferPointer { src in
            workingDepth.withUnsafeBufferPointer { srcD in
                out.withUnsafeMutableBufferPointer { dst in
                    outDepth.withUnsafeMutableBufferPointer { dstD in
                        for row in 0..<r.h {
                            let srcStart = ((r.y0 + row) * width + r.x0) * 4
                            let dstStart = row * r.w * 4
                            memcpy(dst.baseAddress! + dstStart, src.baseAddress! + srcStart,
                                   r.w * 4 * MemoryLayout<Float16>.stride)
                            let srcDStart = (r.y0 + row) * width + r.x0
                            let dstDStart = row * r.w
                            memcpy(dstD.baseAddress! + dstDStart, srcD.baseAddress! + srcDStart,
                                   r.w * MemoryLayout<Float>.stride)
                        }
                    }
                }
            }
        }
        return TileSnapshot(pixels: out, depth: outDepth)
    }

    private func restoreTile(_ tileIndex: Int, snapshot: TileSnapshot) {
        let tx = tileIndex % tilesAcross, ty = tileIndex / tilesAcross
        let r = tileRect(tx: tx, ty: ty)
        working.pixels.withUnsafeMutableBufferPointer { dst in
            displayPixels.withUnsafeMutableBufferPointer { bytes in
                workingDepth.withUnsafeMutableBufferPointer { wd in
                    depthDisplayPixels.withUnsafeMutableBufferPointer { dbytes in
                        snapshot.pixels.withUnsafeBufferPointer { src in
                            snapshot.depth.withUnsafeBufferPointer { srcD in
                                RetouchPaint.restoreTile(
                                    pixels: src.baseAddress!,
                                    depth: srcD.baseAddress!,
                                    working: dst.baseAddress!,
                                    display: bytes.baseAddress!,
                                    workingDepth: wd.baseAddress!,
                                    depthDisplay: dbytes.baseAddress!,
                                    width: width, x0: r.x0, y0: r.y0,
                                    w: r.w, h: r.h,
                                    depthDisplayScale: depthDisplayScale)
                            }
                        }
                    }
                }
            }
        }
        displayGeneration &+= 1
        onDisplayDirty?(CGRect(x: r.x0, y: r.y0, width: r.w, height: r.h))
    }

    // MARK: - Display conversion
    //
    // The per-pixel loops are RetouchPaint's (Kit, -O in every
    // configuration); these wrappers keep the session's array/CGRect
    // surface.

    nonisolated private static func convertToBytes(from buffer: ImageBuffer,
                                                   into bytes: inout [UInt8], rect: CGRect) {
        let x0 = Int(rect.minX), y0 = Int(rect.minY)
        let x1 = min(buffer.width, Int(rect.maxX)), y1 = min(buffer.height, Int(rect.maxY))
        let w = buffer.width
        buffer.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                RetouchPaint.convertToBytes(pixels: src.baseAddress!,
                                            into: dst.baseAddress!,
                                            width: w, x0: x0, x1: x1, y0: y0, y1: y1)
            }
        }
    }

    /// Depth values → visualization bytes (v = 1 − depth·scale, the
    /// DMapFusion.depthImage mapping) for the given rows.
    nonisolated private static func convertDepthToBytes(from depth: [Float], scale: Float,
                                                        into bytes: inout [UInt8],
                                                        width: Int, rows: Range<Int>) {
        depth.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                RetouchPaint.convertDepthToBytes(depth: src.baseAddress!, scale: scale,
                                                 into: dst.baseAddress!,
                                                 width: width, rows: rows)
            }
        }
    }

    nonisolated private static func makeImage(from bytes: [UInt8],
                                              width: Int, height: Int) -> PlatformImage? {
        #if !canImport(CoreGraphics)
        return PlatformImage(width: width, height: height, rgba: bytes)
        #else
        let space = ImageFile.workingSpace
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return bytes.withUnsafeBytes { ptr -> CGImage? in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: info.rawValue) else { return nil }
            return ctx.makeImage()
        }
        #endif
    }
}
