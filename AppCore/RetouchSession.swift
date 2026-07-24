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
    /// Long-build status for the loading overlay ("Building PMax layer… 40%").
    @Published public private(set) var sourceStatus: String?
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
    private let stackSource: StackSource

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

    // Aligned source frames: float pixels for painting, CGImage for the pane.
    // Published because `canPaint` derives from it (the result layer is
    // paintable while its pane preview still renders, so `sourceLoading`
    // alone can't drive the brush circle).
    @Published private(set) var sourceFloat: ImageBuffer?
    private var sourceCache: [Int: (buffer: ImageBuffer, image: PlatformImage)] = [:]
    private var sourceCacheOrder: [Int] = []
    private var sourceLoadGeneration = 0

    // PMax blend layer: a pyramid fusion of the whole stack, selectable as a
    // brush source for regions where structures at different depths overlap
    // (crossing bristles, crystals) and a single depth per pixel is wrong.
    var pmaxIndex: Int { urls.count }
    var isPMaxSource: Bool { sourceIndex == pmaxIndex }
    private var pmaxCache: (buffer: ImageBuffer, image: PlatformImage)?
    private var pmaxBuildCancel: CancellationToken?
    private var lastFrameSourceIndex = 0

    // Original fused result as a brush source — the eraser: paint the pristine
    // fusion back exactly where a stroke overreached, without undoing
    // everything since. Free: the buffer is retained for the session anyway;
    // only its pane preview is built (once) on first use.
    var resultIndex: Int { urls.count + 1 }
    var isResultSource: Bool { sourceIndex == resultIndex }
    private let originalResult: ImageBuffer
    private var resultImageCache: PlatformImage?

    public var sourceName: String {
        isPMaxSource ? NSLocalizedString("PMax blend layer", comment: "")
            : isResultSource ? NSLocalizedString("Original result (eraser)", comment: "")
            : String(format: NSLocalizedString("%@ (aligned)", comment: ""),
                     urls[sourceIndex].lastPathComponent)
    }

    /// The three kinds of brush source, for the "Retouch from" radio group.
    public enum SourceKind: Hashable {
        case frame   // an aligned source slice (↑/↓ picks which)
        case pmax    // the PMax blend layer
        case result  // the original fused result (eraser)
    }

    public var sourceKind: SourceKind {
        isPMaxSource ? .pmax : isResultSource ? .result : .frame
    }

    public func selectKind(_ kind: SourceKind) {
        switch kind {
        case .frame: selectSource(lastFrameSourceIndex)
        case .pmax: selectSource(pmaxIndex)
        case .result: selectSource(resultIndex)
        }
    }

    /// User-facing cancel for the on-demand PMax build (a full pyramid fuse —
    /// minutes at 45 MP): abandon it and fall back to the last frame source.
    /// The layer never arrives, so keeping the PMax selection would strand an
    /// empty pane. selectSource does the actual teardown (cancels the token,
    /// supersedes the load generation).
    public func cancelPMaxBuild() {
        guard isPMaxSource, sourceLoading else { return }
        selectSource(lastFrameSourceIndex)
    }

    // Tile-based per-stroke undo. Snapshots carry the depth plane alongside
    // the pixels — strokes co-paint depth, so undo must restore both.
    private struct TileSnapshot {
        var pixels: [Float]
        var depth: [Float]
    }
    private static let tileSize = 256
    private static let maxUndoStrokes = 20
    private var currentStrokeTiles: [Int: TileSnapshot] = [:]
    private var undoStack: [[Int: TileSnapshot]] = []
    private var redoStack: [[Int: TileSnapshot]] = []
    private var strokeActive = false

    /// `source` must be the same StackSource configuration the fusion used
    /// (including any common-coverage crop) so aligned slices match the
    /// result. `restoredWorking` re-installs retouch edits from a saved
    /// session.
    init(result: ImageBuffer, depth: [Float], sharpness: FrameSharpness?,
         source: StackSource,
         restoredWorking: ImageBuffer? = nil, initialSourceIndex: Int? = nil) {
        self.urls = source.urls
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
        self.workingDepth = depth
        self.originalDepth = depth
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
        Self.convertDepthToBytes(from: depth, scale: depthDisplayScale,
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

    func selectSource(_ index: Int) {
        // pmaxIndex and resultIndex are valid selections (the blend/eraser
        // layers); everything else clamps to the frame list. Cycling off a
        // layer lands on a frame.
        let clamped = index == pmaxIndex || index == resultIndex
            ? index : min(max(index, 0), urls.count - 1)
        if clamped == pmaxIndex {
            selectPMaxLayer()
            return
        }
        if clamped == resultIndex {
            selectResultLayer()
            return
        }
        lastFrameSourceIndex = clamped
        pmaxBuildCancel?.cancel()
        let changed = clamped != sourceIndex
        sourceIndex = clamped
        if changed { onSourceChanged?(clamped) }
        // Supersede in-flight async work BEFORE the cache check — a cache
        // hit must bump the generation too, or stragglers from an abandoned
        // load/build still pass the staleness guards below (a building PMax
        // layer kept stomping a cache-hit frame's pane with its low-res
        // progress previews, then nulled the paint source on cancellation:
        // blurry source pane over a sharp brush).
        sourceLoadGeneration += 1
        if let cached = sourceCache[clamped] {
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
                        ? String(format: NSLocalizedString("Couldn't load %@", comment: ""),
                                 url.lastPathComponent)
                        : String(format: NSLocalizedString("%@ is missing", comment: ""),
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

    public func toggleResultLayer() {
        selectSource(isResultSource ? lastFrameSourceIndex : resultIndex)
    }

    /// The PMax layer is fused on demand (a full pyramid pass over the stack —
    /// minutes at 45 MP) and cached for the session's lifetime.
    private func selectPMaxLayer() {
        // Same rules as selectSource: supersede stragglers even on a cache
        // hit, and never leave a previous build running unobserved.
        pmaxBuildCancel?.cancel()
        let changed = sourceIndex != pmaxIndex
        sourceIndex = pmaxIndex
        if changed { onSourceChanged?(pmaxIndex) }
        sourceLoadGeneration += 1
        if let cached = pmaxCache {
            sourceFloat = cached.buffer
            sourceDisplay = cached.image
            sourceLoading = false
            sourceStatus = nil
            sourceError = nil
            return
        }
        sourceFloat = nil
        sourceDisplay = nil
        sourceLoading = true
        sourceError = nil
        sourceStatus = NSLocalizedString("Building PMax layer…", comment: "")
        let generation = sourceLoadGeneration
        let source = stackSource
        let cancel = CancellationToken()
        pmaxBuildCancel = cancel
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded: (buffer: ImageBuffer, image: PlatformImage)?
            do {
                let fusedImage = try PyramidFusion.fuse(source: source,
                                                        progress: { fraction, preview in
                    // Show the forming pyramid while it builds (GPU path
                    // emits low-res collapses; CPU sends none). Converted
                    // off-main — these arrive from the fusion thread.
                    let image = preview
                        .flatMap { try? Preview.image(from: $0) }
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.sourceLoadGeneration else { return }
                        self.sourceStatus = String(format: NSLocalizedString(
                            "Building PMax layer… %lld%%", comment: ""), Int(fraction * 100))
                        if let image { self.sourceDisplay = image }
                    }
                }, cancellation: cancel,
                                                        // Focus-gate the PMax blend layer: a paint
                                                        // source carrying highlight bloom would paint
                                                        // that bloom into the result. Runs on CPU or
                                                        // GPU (parity ≥ standard PMax).
                                                        focusGate: .init())
                loaded = (fusedImage, try Preview.image(from: fusedImage))
            } catch {
                loaded = nil
                if !(error is CancellationError) {
                    FileHandle.standardError.write(
                        Data("retouch: pmax build failed: \(error)\n".utf8))
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let loaded { self.pmaxCache = loaded }
                guard generation == self.sourceLoadGeneration else { return }
                self.sourceFloat = loaded?.buffer
                self.sourceDisplay = loaded?.image
                self.sourceLoading = false
                self.sourceStatus = nil
                self.sourceError = loaded == nil
                    ? NSLocalizedString("Couldn't build the PMax layer", comment: "") : nil
            }
        }
    }

    /// The eraser layer is instantly paintable (the pristine result is already
    /// in memory); only its pane preview needs a one-time 8-bit render.
    private func selectResultLayer() {
        pmaxBuildCancel?.cancel()
        let changed = sourceIndex != resultIndex
        sourceIndex = resultIndex
        if changed { onSourceChanged?(resultIndex) }
        sourceLoadGeneration += 1  // supersede any in-flight frame/PMax load
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
        // Keep 3 full-res float frames at most (~2 GB at 45 MP).
        while sourceCacheOrder.count > 3 {
            sourceCache.removeValue(forKey: sourceCacheOrder.removeFirst())
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
            if undoStack.count > Self.maxUndoStrokes {
                undoStack.removeFirst()
            }
            redoStack = []
            canUndo = true
            canRedo = false
            hasEdits = true
            onEdited?()
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

    private func captureTiles<S: Sequence>(_ tiles: S) -> [Int: TileSnapshot]
        where S.Element == Int {
        var snapshot = [Int: TileSnapshot]()
        for tileIndex in tiles {
            snapshot[tileIndex] = copyTile(tx: tileIndex % tilesAcross,
                                           ty: tileIndex / tilesAcross)
        }
        return snapshot
    }

    func resetAll(to original: ImageBuffer) {
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

        let w = width
        // The stroke's depth: a frame paints its own index (that IS the
        // depth of the pixels being copied), the eraser paints the
        // session-start depth back, and PMax — whose pixels have no single
        // depth — leaves the plane alone.
        let paintsDepth = !isPMaxSource
        let eraseDepth = isResultSource
        let frameDepth = Float(min(sourceIndex, urls.count - 1))
        let dScale = depthDisplayScale
        working.pixels.withUnsafeMutableBufferPointer { dst in
            src.pixels.withUnsafeBufferPointer { s in
                displayPixels.withUnsafeMutableBufferPointer { bytes in
                    workingDepth.withUnsafeMutableBufferPointer { wd in
                        originalDepth.withUnsafeBufferPointer { od in
                            depthDisplayPixels.withUnsafeMutableBufferPointer { dbytes in
                    let innerSq = inner * inner
                    let count = w * self.height
                    dst.baseAddress!.withMemoryRebound(to: SIMD4<Float>.self, capacity: count) { dstV in
                    s.baseAddress!.withMemoryRebound(to: SIMD4<Float>.self, capacity: count) { srcV in
                    bytes.baseAddress!.withMemoryRebound(to: SIMD4<UInt8>.self, capacity: count) { bytesV in
                    let dstBox = UncheckedSendable(dstV)
                    let srcBox = UncheckedSendable(srcV)
                    let bytesBox = UncheckedSendable(bytesV)
                    let wdBox = UncheckedSendable(wd)
                    let odBox = UncheckedSendable(od)
                    let dbytesBox = UncheckedSendable(dbytes)
                    let paintRow: @Sendable (Int) -> Void = { y in
                        let dstV = dstBox.value, srcV = srcBox.value
                        let bytesV = bytesBox.value
                        let wd = wdBox.value, od = odBox.value, dbytes = dbytesBox.value
                        let dy = Double(y) - center.y
                        let dySq = dy * dy
                        guard dySq <= r * r else { return }
                        // Row extent from the circle equation: the loop never
                        // visits the bounding square's corners, and pixels in
                        // the hard core skip the square root entirely.
                        let chord = (r * r - dySq).squareRoot()
                        let xLo = max(x0, Int((center.x - chord).rounded(.up)))
                        let xHi = min(x1, Int((center.x + chord).rounded(.down)))
                        guard xLo <= xHi else { return }
                        for x in xLo...xHi {
                            let dx = Double(x) - center.x
                            let dSq = dx * dx + dySq
                            let t: Double
                            if dSq <= innerSq || r <= inner {
                                t = 1
                            } else {
                                let d = dSq.squareRoot()
                                t = min(max((r - d) / (r - inner), 0), 1)
                            }
                            let pi = y * w + x
                            // Respect source coverage: alpha 0 means the aligned
                            // frame has no data here (warp out-of-bounds) — never
                            // paint smear colors from past its edge.
                            let sv = srcV[pi]
                            let alpha = Float(t * t * (3 - 2 * t)) * sv.w
                            guard alpha > 0.003 else { continue }
                            // Same arithmetic as the scalar path had
                            // (d·(1−α) + s·α), one vector op per pixel.
                            var out = dstV[pi] * (1 - alpha) + sv * alpha
                            out.w = 1
                            dstV[pi] = out
                            // hfMin/hfMax: the stdlib generic stays witness-
                            // dispatched at -O on the Mac toolchain (see
                            // PortableSIMD's contract).
                            let scaled = hfMin(hfMax(out, .zero), .one)
                                * 255 + SIMD4<Float>(repeating: 0.5)
                            bytesV[pi] = SIMD4<UInt8>(scaled)
                            if paintsDepth {
                                let target = eraseDepth ? od[pi] : frameDepth
                                let v = wd[pi] * (1 - alpha) + target * alpha
                                wd[pi] = v
                                let g = 1 - v * dScale
                                dbytes[pi] = UInt8(min(max(g, 0), 1) * 255 + 0.5)
                            }
                        }
                    }
                    // Rows write disjoint memory in every buffer — safe to
                    // fan out (the convertToBytes structural argument). Small
                    // brushes stay serial; the dispatch overhead would win.
                    let rows = y1 - y0 + 1
                    if rows >= 128 {
                        DispatchQueue.concurrentPerform(iterations: rows) { i in
                            paintRow(y0 + i)
                        }
                    } else {
                        for y in y0...y1 { paintRow(y) }
                    }
                    }
                    }
                    }
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
        var out = [Float](repeating: 0, count: r.w * r.h * 4)
        var outDepth = [Float](repeating: 0, count: r.w * r.h)
        working.pixels.withUnsafeBufferPointer { src in
            workingDepth.withUnsafeBufferPointer { srcD in
                out.withUnsafeMutableBufferPointer { dst in
                    outDepth.withUnsafeMutableBufferPointer { dstD in
                        for row in 0..<r.h {
                            let srcStart = ((r.y0 + row) * width + r.x0) * 4
                            let dstStart = row * r.w * 4
                            memcpy(dst.baseAddress! + dstStart, src.baseAddress! + srcStart,
                                   r.w * 4 * MemoryLayout<Float>.stride)
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
        let dScale = depthDisplayScale
        working.pixels.withUnsafeMutableBufferPointer { dst in
            displayPixels.withUnsafeMutableBufferPointer { bytes in
                snapshot.pixels.withUnsafeBufferPointer { src in
                    for row in 0..<r.h {
                        let dstStart = ((r.y0 + row) * width + r.x0) * 4
                        let srcStart = row * r.w * 4
                        for i in 0..<(r.w * 4) {
                            let v = src[srcStart + i]
                            dst[dstStart + i] = v
                            bytes[dstStart + i] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                        }
                    }
                }
            }
        }
        workingDepth.withUnsafeMutableBufferPointer { dst in
            depthDisplayPixels.withUnsafeMutableBufferPointer { bytes in
                snapshot.depth.withUnsafeBufferPointer { src in
                    for row in 0..<r.h {
                        let dstStart = (r.y0 + row) * width + r.x0
                        let srcStart = row * r.w
                        for i in 0..<r.w {
                            let v = src[srcStart + i]
                            dst[dstStart + i] = v
                            let g = 1 - v * dScale
                            bytes[dstStart + i] = UInt8(min(max(g, 0), 1) * 255 + 0.5)
                        }
                    }
                }
            }
        }
        displayGeneration &+= 1
        onDisplayDirty?(CGRect(x: r.x0, y: r.y0, width: r.w, height: r.h))
    }

    // MARK: - Display conversion

    /// Wrapper for pointer captures in concurrentPerform's @Sendable closure.
    /// Safety is structural: each iteration writes a disjoint row, and the
    /// pointers outlive the (synchronous) call.
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    nonisolated private static func convertToBytes(from buffer: ImageBuffer,
                                                   into bytes: inout [UInt8], rect: CGRect) {
        let w = buffer.width
        let x0 = Int(rect.minX), y0 = Int(rect.minY)
        let x1 = min(buffer.width, Int(rect.maxX)), y1 = min(buffer.height, Int(rect.maxY))
        buffer.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                let srcBox = UncheckedSendable(src)
                let dstBox = UncheckedSendable(dst)
                DispatchQueue.concurrentPerform(iterations: y1 - y0) { row in
                    let src = srcBox.value, dst = dstBox.value
                    let y = y0 + row
                    for i in ((y * w + x0) * 4)..<((y * w + x1) * 4) {
                        dst[i] = UInt8(min(max(src[i], 0), 1) * 255 + 0.5)
                    }
                }
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
                let srcBox = UncheckedSendable(src)
                let dstBox = UncheckedSendable(dst)
                DispatchQueue.concurrentPerform(iterations: rows.count) { row in
                    let src = srcBox.value, dst = dstBox.value
                    let y = rows.lowerBound + row
                    for i in (y * width)..<((y + 1) * width) {
                        let v = 1 - src[i] * scale
                        dst[i] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                    }
                }
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
