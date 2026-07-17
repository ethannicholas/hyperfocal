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

    public init(urls: [URL], transforms: [simd_float3x3]? = nil,
                outputWidth: Int? = nil, outputHeight: Int? = nil) {
        precondition(transforms == nil || transforms!.count == urls.count)
        self.urls = urls
        self.transforms = transforms
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    public var count: Int { urls.count }

    public func frame(at i: Int) throws -> ImageBuffer {
        var img = try ImageFile.load(url: urls[i])
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
