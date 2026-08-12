import Foundation
#if canImport(simd)
import simd
#endif

/// Streaming access to a focus stack on disk: frames are decoded (and warped into
/// the reference coordinate system) one at a time, on demand. Nothing is retained
/// between calls, so memory stays flat regardless of stack depth.
public struct StackSource {
    public let urls: [URL]
    public let transforms: [simd_float3x3]?  // frame → reference, per frame
    /// Output canvas size; when set (common-coverage crop), warping targets it
    /// instead of the frame's own dimensions.
    public let outputWidth: Int?
    public let outputHeight: Int?
    /// Per-frame, per-channel exposure gains from a fusion (`Output.gains`),
    /// applied to decoded frames so retouch stamps match the normalized
    /// result. Leave nil for fusion itself — it measures and applies gains
    /// internally.
    public var gains: [SIMD3<Float>]?
    /// Frames already decoded by the registration pass. Consulted before
    /// hitting the disk, and destructive on read, so the stack is decoded once
    /// per fuse rather than once for registration and again for fusion. Only
    /// ever populated for the input classes where registration had to build the
    /// full buffer regardless — see `DecodedFrameCache`. nil (and empty) leaves
    /// behavior exactly as it was.
    public var decoded: DecodedFrameCache?
    /// A frame cache over the SAME frame list and canvas — either a fuse's
    /// retained spill (`Options.retainSpill` → `Output.warpedFrames`,
    /// complete by construction) or a lazily-filled one
    /// (`WarpedFrameCache.lazyCache`). `frame(at:)` streams a cached slot off
    /// SSD instead of decoding (and, with transforms, warping); a MISSED slot
    /// decodes normally and is written back, so the cache fills with use —
    /// partial coverage is partial speedup, never an error. The slots hold
    /// pre-gain pixels (aligned sources: post-warp, exactly what the fused
    /// render consumed; transform-less sources: the raw decode), and gains
    /// apply after streaming, matching the render pass. Mismatched dimensions
    /// or frame count, or a failed read, fall back to the decode path. Never
    /// set by fusion itself — its consumers there go through
    /// `StackPipeline.Configuration.warpedFrameCache`.
    public var warped: WarpedFrameCache?

    public init(urls: [URL], transforms: [simd_float3x3]? = nil,
                outputWidth: Int? = nil, outputHeight: Int? = nil) {
        precondition(transforms == nil || transforms!.count == urls.count)
        self.urls = urls
        self.transforms = transforms
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    public var count: Int { urls.count }

    /// Decoded frame with exposure gains applied and **no warp** — what the
    /// GPU pyramid engines want, since they align on the device and so must not
    /// be handed a CPU-warped frame. Both `PyramidFusion.fuse(source:)` and
    /// `DMapFusion.fuseWithDepth(source:)` open-coded these three lines; they
    /// share this instead, so the decode path has one place to consult the
    /// registration-decode cache. Missing that this was two seams and not one
    /// is why the first cut of the cache filled correctly and was never read.
    public func decodedFrame(at i: Int) throws -> ImageBuffer {
        // The cached buffer is the output of the same deterministic
        // `ImageFile.loadRAW` call this would otherwise make, so the two are
        // bit-identical and this needs no tolerance.
        var img = try decoded?.take(urls[i]) ?? ImageFile.load(url: urls[i])
        if let gain = gains?[i], gain != SIMD3(repeating: 1) {
            img.scaleRGB(by: gain)
        }
        return img
    }

    /// Whether `warped` provably covers this source: same frame count, and —
    /// for aligned sources — the cache's canvas is this source's output
    /// canvas. A transform-less source has no fixed canvas; there the cache
    /// is keyed to the frames' native size and `store`'s per-frame dimension
    /// guard is the gate (a frame whose decode doesn't match the slot
    /// geometry is simply never cached, so a hit can't lie).
    private func covers(_ cache: WarpedFrameCache) -> Bool {
        cache.frameCount == urls.count
            && (transforms == nil
                || (cache.width == outputWidth && cache.height == outputHeight))
    }

    public func frame(at i: Int) throws -> ImageBuffer {
        // A cached slot wins outright. try? — an unwritten slot (partial
        // cache) or a read error (the temp volume yanked mid-session)
        // degrades to re-decoding, the same contract the fusion passes have.
        if let cache = warped, covers(cache), var img = try? cache.frame(i) {
            if let gain = gains?[i], gain != SIMD3(repeating: 1) {
                img.scaleRGB(by: gain)
            }
            return img
        }
        var img = try decoded?.take(urls[i]) ?? ImageFile.load(url: urls[i])
        // Warp BEFORE gain (they commute — gain is a per-pixel linear scale,
        // the warp a linear filter) so the written-back slot holds pre-gain
        // pixels, the spill convention fusion set: gains always apply after
        // streaming, and a slot never double-gains.
        if let t = transforms?[i] {
            let w = outputWidth ?? img.width
            let h = outputHeight ?? img.height
            if !(t == matrix_identity_float3x3 && w == img.width && h == img.height) {
                img = Warp.apply(img, outputToSource: t.inverse, outWidth: w, outHeight: h)
            }
        }
        // Write the miss back — the next visit to this frame streams. Skipped
        // silently when the cache doesn't cover this source or the decode's
        // dimensions don't match its slots (mixed-size stack).
        if let cache = warped, covers(cache) {
            cache.store(frame: i, buffer: img)
        }
        if let gain = gains?[i], gain != SIMD3(repeating: 1) {
            img.scaleRGB(by: gain)
        }
        return img
    }
}
