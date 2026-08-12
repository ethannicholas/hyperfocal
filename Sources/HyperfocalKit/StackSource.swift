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

    public func frame(at i: Int) throws -> ImageBuffer {
        var img = try decoded?.take(urls[i]) ?? ImageFile.load(url: urls[i])
        if let gain = gains?[i], gain != SIMD3(repeating: 1) {
            img.scaleRGB(by: gain)
        }
        guard let t = transforms?[i] else { return img }
        let w = outputWidth ?? img.width
        let h = outputHeight ?? img.height
        if t == matrix_identity_float3x3 && w == img.width && h == img.height {
            return img
        }
        return Warp.apply(img, outputToSource: t.inverse, outWidth: w, outHeight: h)
    }
}
