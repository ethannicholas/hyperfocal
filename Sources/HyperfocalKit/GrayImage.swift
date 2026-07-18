import Foundation

/// An 8-bit grayscale image: one byte per pixel, row 0 = top, row-major. The
/// portable currency for registration — the seam `Aligner.register` works on,
/// replacing `CGImage` (which is Apple-only). On macOS the bytes are produced
/// by the same CoreGraphics draws as before and wrapped straight back into a
/// `CGImage` for Vision, so the registration input is byte-identical; on Linux
/// they come from the imaging shim and feed OpenCV.
public struct GrayImage {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]   // count = width * height

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "gray pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
