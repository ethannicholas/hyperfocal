import SwiftUI
import HyperfocalKit
import simd
import os

/// A retouching session over a fused result: a mutable working copy of the
/// output that brush strokes paint into, sourcing pixels from *aligned* input
/// frames. Undo is per-stroke via 256px tile snapshots. The fusion's
/// regularized depth plane doubles as an instant "sharpest frame here" oracle
/// for the space-key auto-pick.
@MainActor
final class RetouchSession: ObservableObject {

    let urls: [URL]                 // the frame list the fusion ran on, in order
    let width: Int
    let height: Int
    var nominalSize: CGSize { CGSize(width: width, height: height) }

    private static let log = Logger(subsystem: "org.hyperfocal", category: "retouch")

    @Published private(set) var sourceIndex: Int
    @Published private(set) var sourceDisplay: NSImage? {
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
                  let rep = image.representations.first,
                  rep.pixelsWide > 0, rep.pixelsWide < width / 2 else { return }
            Self.log.fault("""
                retouch source pane got a \(rep.pixelsWide)x\(rep.pixelsHigh) image \
                for a \(self.width)x\(self.height) frame (index \(self.sourceIndex))
                """)
        }
    }
    @Published private(set) var sourceLoading = false
    @Published private(set) var sourceError: String?
    /// Long-build status for the loading overlay ("Building PMax layer… 40%").
    @Published private(set) var sourceStatus: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasEdits = false
    @Published var cursor: CGPoint?          // hover location, image coords
    @Published var brushRadius: Double = 32  // image px
    @Published var brushSoftness: Double = 0.2
    /// True from a mouse-down that found no source pixels (still loading)
    /// until its mouse-up: that drag never paints, so the brush circle stays
    /// hidden for its whole duration even if the load lands mid-drag.
    @Published private(set) var deadDrag = false

    /// Whether a stroke would actually paint right now. The panes only show
    /// the brush circle when it's honest — a circle over a still-loading
    /// source (or during a dead drag) promises painting that can't happen.
    var canPaint: Bool { sourceFloat != nil && !deadDrag }

    private(set) var working: ImageBuffer
    private let depth: [Float]
    private let sharpness: FrameSharpness?
    private let stackSource: StackSource

    private var displayPixels: [UInt8]
    /// The canvas view registers here; strokes report the image-space rect they
    /// touched so only that region repaints (NOT a full-frame image rebuild —
    /// that was unusably slow at 45 MP).
    var onDisplayDirty: ((CGRect) -> Void)?
    /// Fired when the source frame changes (arrows / space / programmatic), so
    /// the app can keep the Stack list selection in sync.
    var onSourceChanged: ((Int) -> Void)?
    /// Fired whenever the working pixels change (stroke, undo, redo, revert) —
    /// the app tracks unsaved work with it.
    var onEdited: (() -> Void)?

    // Aligned source frames: float pixels for painting, NSImage for the pane.
    // Published because `canPaint` derives from it (the result layer is
    // paintable while its pane preview still renders, so `sourceLoading`
    // alone can't drive the brush circle).
    @Published private(set) var sourceFloat: ImageBuffer?
    private var sourceCache: [Int: (buffer: ImageBuffer, image: NSImage)] = [:]
    private var sourceCacheOrder: [Int] = []
    private var sourceLoadGeneration = 0

    // PMax blend layer: a pyramid fusion of the whole stack, selectable as a
    // brush source for regions where structures at different depths overlap
    // (crossing bristles, crystals) and a single depth per pixel is wrong.
    var pmaxIndex: Int { urls.count }
    var isPMaxSource: Bool { sourceIndex == pmaxIndex }
    private var pmaxCache: (buffer: ImageBuffer, image: NSImage)?
    private var pmaxBuildCancel: CancellationToken?
    private var lastFrameSourceIndex = 0

    // Original fused result as a brush source — the eraser: paint the pristine
    // fusion back exactly where a stroke overreached, without undoing
    // everything since. Free: the buffer is retained for the session anyway;
    // only its pane preview is built (once) on first use.
    var resultIndex: Int { urls.count + 1 }
    var isResultSource: Bool { sourceIndex == resultIndex }
    private let originalResult: ImageBuffer
    private var resultImageCache: NSImage?

    var sourceName: String {
        isPMaxSource ? "PMax blend layer"
            : isResultSource ? "Original result (eraser)"
            : "\(urls[sourceIndex].lastPathComponent) (aligned)"
    }

    /// The three kinds of brush source, for the "Retouch from" radio group.
    enum SourceKind: Hashable {
        case frame   // an aligned source slice (↑/↓ picks which)
        case pmax    // the PMax blend layer
        case result  // the original fused result (eraser)
    }

    var sourceKind: SourceKind {
        isPMaxSource ? .pmax : isResultSource ? .result : .frame
    }

    func selectKind(_ kind: SourceKind) {
        switch kind {
        case .frame: selectSource(lastFrameSourceIndex)
        case .pmax: selectSource(pmaxIndex)
        case .result: selectSource(resultIndex)
        }
    }

    // Tile-based per-stroke undo.
    private static let tileSize = 256
    private static let maxUndoStrokes = 20
    private var currentStrokeTiles: [Int: [Float]] = [:]
    private var undoStack: [[Int: [Float]]] = []
    private var redoStack: [[Int: [Float]]] = []
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
        self.depth = depth
        self.sharpness = sharpness
        self.stackSource = source
        self.sourceIndex = initialSourceIndex.map { min(max($0, 0), source.count - 1) }
            ?? source.count / 2

        var pixels = [UInt8](repeating: 0, count: result.width * result.height * 4)
        Self.convertToBytes(from: working, into: &pixels,
                            rect: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        self.displayPixels = pixels

        selectSource(sourceIndex)
    }

    // MARK: - Display access

    /// Zero-copy CGImage over the live display bytes, valid within `body` only.
    func withDisplayCGImage<R>(_ body: (CGImage?) -> R) -> R {
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
    }

    /// One-off full snapshot (used when leaving retouch mode).
    func makeSnapshotImage() -> NSImage? {
        Self.makeImage(from: displayPixels, width: width, height: height)
    }

    func adjustBrushRadius(by factor: Double) {
        brushRadius = min(max(brushRadius * factor, 5), 1500)
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
            let loaded: (buffer: ImageBuffer, image: NSImage)?
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
                        ? "Couldn't load \(url.lastPathComponent)"
                        : "\(url.lastPathComponent) is missing")
                    : nil
                if loaded != nil {
                    self.prefetchNeighbors(of: clamped)
                }
            }
        }
    }


    func cycleSource(by delta: Int) {
        if sourceIndex >= urls.count {
            selectSource(lastFrameSourceIndex)  // arrows leave the blend/eraser layers
        } else {
            selectSource(sourceIndex + delta)
        }
    }

    func togglePMaxLayer() {
        selectSource(isPMaxSource ? lastFrameSourceIndex : pmaxIndex)
    }

    func toggleResultLayer() {
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
        sourceStatus = "Building PMax layer…"
        let generation = sourceLoadGeneration
        let source = stackSource
        let cancel = CancellationToken()
        pmaxBuildCancel = cancel
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded: (buffer: ImageBuffer, image: NSImage)?
            do {
                let fusedImage = try PyramidFusion.fuse(source: source,
                                                        progress: { fraction, preview in
                    // Show the forming pyramid while it builds (GPU path
                    // emits low-res collapses; CPU sends none). Converted
                    // off-main — these arrive from the fusion thread.
                    let image = preview
                        .flatMap { try? ImageFile.cgImage8(from: $0) }
                        .map { NSImage(cgImage: $0, size: .zero) }
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.sourceLoadGeneration else { return }
                        self.sourceStatus = "Building PMax layer… \(Int(fraction * 100))%"
                        if let image { self.sourceDisplay = image }
                    }
                }, cancellation: cancel)
                let cg = try ImageFile.cgImage8(from: fusedImage)
                loaded = (fusedImage, NSImage(cgImage: cg, size: .zero))
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
                self.sourceError = loaded == nil ? "Couldn't build the PMax layer" : nil
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
            let image = (try? ImageFile.cgImage8(from: buffer))
                .map { NSImage(cgImage: $0, size: .zero) }
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
    func autoPickSource(at point: CGPoint) {
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
                    let index = Int(depth[y * width + x].rounded())
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

    private func cacheSource(_ loaded: (buffer: ImageBuffer, image: NSImage), at index: Int) {
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
        throws -> (buffer: ImageBuffer, image: NSImage) {
        let buffer = try source.frame(at: index)
        let cg = try ImageFile.cgImage8(from: buffer)
        return (buffer, NSImage(cgImage: cg, size: .zero))
    }

    // MARK: - Painting

    func beginStroke(at point: CGPoint) {
        guard sourceFloat != nil else {
            deadDrag = true
            return
        }
        strokeActive = true
        currentStrokeTiles = [:]
        stamp(at: point)
    }

    func continueStroke(from p0: CGPoint, to p1: CGPoint) {
        guard strokeActive, sourceFloat != nil else { return }
        let distance = hypot(p1.x - p0.x, p1.y - p0.y)
        let spacing = max(1, brushRadius / 3)
        let steps = max(1, Int(distance / spacing))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            stamp(at: CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
        }
    }

    func endStroke() {
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
        for (tileIndex, pixels) in stroke {
            restoreTile(tileIndex, pixels: pixels)
        }
        canUndo = !undoStack.isEmpty
        canRedo = true
        onEdited?()
    }

    func redo() {
        guard let stroke = redoStack.popLast() else { return }
        undoStack.append(captureTiles(stroke.keys))
        for (tileIndex, pixels) in stroke {
            restoreTile(tileIndex, pixels: pixels)
        }
        canRedo = !redoStack.isEmpty
        canUndo = true
        hasEdits = true
        onEdited?()
    }

    private func captureTiles<S: Sequence>(_ tiles: S) -> [Int: [Float]]
        where S.Element == Int {
        var snapshot = [Int: [Float]]()
        for tileIndex in tiles {
            snapshot[tileIndex] = copyTile(tx: tileIndex % tilesAcross,
                                           ty: tileIndex / tilesAcross)
        }
        return snapshot
    }

    func resetAll(to original: ImageBuffer) {
        working = original
        undoStack = []
        redoStack = []
        currentStrokeTiles = [:]
        canUndo = false
        canRedo = false
        hasEdits = false
        Self.convertToBytes(from: working, into: &displayPixels,
                            rect: CGRect(x: 0, y: 0, width: width, height: height))
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
        working.pixels.withUnsafeMutableBufferPointer { dst in
            src.pixels.withUnsafeBufferPointer { s in
                displayPixels.withUnsafeMutableBufferPointer { bytes in
                    for y in y0...y1 {
                        let dy = Double(y) - center.y
                        for x in x0...x1 {
                            let dx = Double(x) - center.x
                            let d = (dx * dx + dy * dy).squareRoot()
                            guard d <= r else { continue }
                            let t = r > inner
                                ? min(max((r - d) / (r - inner), 0), 1)
                                : 1
                            let pi = (y * w + x) * 4
                            // Respect source coverage: alpha 0 means the aligned
                            // frame has no data here (warp out-of-bounds) — never
                            // paint smear colors from past its edge.
                            let alpha = Float(t * t * (3 - 2 * t)) * s[pi + 3]
                            guard alpha > 0.003 else { continue }
                            for c in 0..<3 {
                                let v = dst[pi + c] * (1 - alpha) + s[pi + c] * alpha
                                dst[pi + c] = v
                                bytes[pi + c] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                            }
                            dst[pi + 3] = 1
                            bytes[pi + 3] = 255
                        }
                    }
                }
            }
        }
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

    private func copyTile(tx: Int, ty: Int) -> [Float] {
        let r = tileRect(tx: tx, ty: ty)
        var out = [Float](repeating: 0, count: r.w * r.h * 4)
        working.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<r.h {
                    let srcStart = ((r.y0 + row) * width + r.x0) * 4
                    let dstStart = row * r.w * 4
                    for i in 0..<(r.w * 4) {
                        dst[dstStart + i] = src[srcStart + i]
                    }
                }
            }
        }
        return out
    }

    private func restoreTile(_ tileIndex: Int, pixels: [Float]) {
        let tx = tileIndex % tilesAcross, ty = tileIndex / tilesAcross
        let r = tileRect(tx: tx, ty: ty)
        working.pixels.withUnsafeMutableBufferPointer { dst in
            displayPixels.withUnsafeMutableBufferPointer { bytes in
                pixels.withUnsafeBufferPointer { src in
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

    nonisolated private static func makeImage(from bytes: [UInt8],
                                              width: Int, height: Int) -> NSImage? {
        let space = ImageFile.workingSpace
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return bytes.withUnsafeBytes { ptr -> NSImage? in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: info.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }
    }
}
