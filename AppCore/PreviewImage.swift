// The display-image currency AppCore publishes (previews, progressive
// frames, depth views). On Apple platforms it IS CGImage — the native
// views and the bridge's tile server consume it with zero conversion —
// and elsewhere it is a plain 8-bit RGBA buffer the Qt shell's tile
// calls copy from. Preview.image(from:) is the one production seam:
// everything AppCore turns into a displayable image goes through it.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HyperfocalKit

#if canImport(CoreGraphics)
public typealias PlatformImage = CGImage
#else
/// 8-bit RGBA image, row-major, width*4 stride — mirrors the CGImage
/// surface AppCore's clients touch (width/height + pixel access).
public final class PlatformImage {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Clamp-to-8-bit conversion, the non-CG counterpart of
    /// ImageFile.cgImage8's byte mapping.
    public convenience init(buffer: ImageBuffer) {
        var bytes = [UInt8](repeating: 255, count: buffer.width * buffer.height * 4)
        buffer.pixels.withUnsafeBufferPointer { src in
            for i in 0..<(buffer.width * buffer.height) {
                for c in 0..<3 {
                    let v = src[i * 4 + c]
                    bytes[i * 4 + c] = UInt8((max(0, min(1, v)) * 255).rounded())
                }
            }
        }
        self.init(width: buffer.width, height: buffer.height, rgba: bytes)
    }
}
#endif

public enum Preview {
    /// An ImageBuffer as a displayable preview image.
    public static func image(from buffer: ImageBuffer) throws -> PlatformImage {
        #if canImport(CoreGraphics)
        return try ImageFile.cgImage8(from: buffer)
        #else
        return PlatformImage(buffer: buffer)
        #endif
    }
}
