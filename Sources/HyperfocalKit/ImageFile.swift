import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#else
import CImaging
#endif

public enum ImageFileError: Error, CustomStringConvertible {
    case cannotLoad(String)
    case cannotSave(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .cannotLoad(let s): return "cannot load: \(s)"
        case .cannotSave(let s): return "cannot save: \(s)"
        case .unsupported(let s): return "unsupported: \(s)"
        }
    }
}

public enum ImageFile {

    /// Identifier persisted in project manifests; restoring a project written
    /// in a different working space is refused rather than color-shifted.
    public static let workingSpaceName = "display-p3"

    /// Camera RAW extensions decoded through the RAW pipeline (demosaic +
    /// as-shot white balance) instead of a plain raster decoder.
    public static let rawExtensions: Set<String> = [
        "nef", "nrw", "dng", "cr2", "cr3", "crw", "arw", "raf", "orf", "rw2",
        "pef", "srw", "3fr", "fff", "iiq", "rwl",
    ]

    public static func isRAW(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

#if canImport(CoreGraphics)

    /// The pipeline's working color space. `ImageBuffer` floats are untagged;
    /// by convention they are Display P3 (P3 primaries, sRGB transfer curve) —
    /// wide enough that saturated subjects survive to export instead of
    /// clipping at decode. Every decode converts into this space and every
    /// CGImage the pipeline creates is tagged with it; exports convert to the
    /// caller's requested space. Fusion math itself is space-agnostic
    /// (per-pixel argmax and blends); the Rec.709 luma constants used for
    /// sharpness/exposure heuristics are fine in any RGB space.
    public static let workingSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    // MARK: - Loading

    /// Pixel dimensions from the file header — no decode.
    public static func pixelSize(url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    public static func load(url: URL) throws -> ImageBuffer {
        if isRAW(url) {
            return try loadRAW(url: url)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageFileError.cannotLoad(url.path)
        }
        return try buffer(from: cg)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Decode camera RAW (NEF incl. lossy/High Efficiency, DNG, CR3, ...) via the
    /// system RAW engine. As-shot settings, no draft mode — deterministic per
    /// file, so a stack shot at fixed WB decodes consistently across frames.
    public static func loadRAW(url: URL) throws -> ImageBuffer {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw ImageFileError.cannotLoad("\(url.lastPathComponent): not a supported RAW")
        }
        filter.isDraftModeEnabled = false
        guard let ci = filter.outputImage else {
            throw ImageFileError.cannotLoad("\(url.lastPathComponent): RAW decode produced no image")
        }
        let extent = ci.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0 && h > 0 else {
            throw ImageFileError.cannotLoad("\(url.lastPathComponent): empty RAW extent")
        }
        let space = workingSpace
        var buf = ImageBuffer(width: w, height: h)
        buf.pixels.withUnsafeMutableBytes { ptr in
            ciContext.render(ci, toBitmap: ptr.baseAddress!, rowBytes: w * 16,
                             bounds: extent, format: .RGBAf, colorSpace: space)
        }
        return buf
    }

    /// Decode any CGImage into Float32 RGBA via a float bitmap context.
    public static func buffer(from cg: CGImage) throws -> ImageBuffer {
        let w = cg.width, h = cg.height
        var buf = ImageBuffer(width: w, height: h)
        let space = workingSpace
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = buf.pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ImageFileError.cannotLoad("cannot create float bitmap context") }
        return buf
    }

    /// Decode a file straight to an 8-bit grayscale CGImage — the cheapest useful
    /// representation for registration (no Float32 conversion, 1/16th the memory).
    /// RAW files go through the RAW pipeline so registration sees the same
    /// geometry as fusion.
    public static func loadGray8CGImage(url: URL) throws -> CGImage {
        if isRAW(url) {
            let img = try loadRAW(url: url)
            return try grayCGImage8(from: img)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageFileError.cannotLoad(url.path)
        }
        let w = cg.width, h = cg.height
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImageFileError.cannotLoad("cannot create grayscale context")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let gray = ctx.makeImage() else {
            throw ImageFileError.cannotLoad("cannot render grayscale image")
        }
        return gray
    }

    /// 8-bit luminance plane for registration (the portable `GrayImage` seam).
    /// Produced from the same grayscale CGImage the Apple path always used, so
    /// the bytes Vision registers on are unchanged.
    public static func loadGray8(url: URL) throws -> GrayImage {
        let cg = try loadGray8CGImage(url: url)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayImage(width: w, height: h, pixels: bytes)
    }

    /// Small Float32 RGBA buffer from any CGImage (grayscale included), drawn at
    /// reduced size — cheap progress-preview conversion.
    public static func previewBuffer(from cg: CGImage, maxSide: Int) throws -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(cg.width, cg.height)))
        let pw = max(1, Int(Double(cg.width) * scale))
        let ph = max(1, Int(Double(cg.height) * scale))
        var buf = ImageBuffer(width: pw, height: ph)
        let space = workingSpace
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = buf.pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: pw, height: ph,
                                      bitsPerComponent: 32, bytesPerRow: pw * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            return true
        }
        guard ok else { throw ImageFileError.cannotLoad("cannot create preview context") }
        return buf
    }

    /// 8-bit grayscale CGImage from a float buffer's luminance.
    public static func grayCGImage8(from image: ImageBuffer) throws -> CGImage {
        let w = image.width, h = image.height
        let lum = image.luminancePlane()
        var bytes = [UInt8](repeating: 0, count: w * h)
        lum.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for i in (y * w)..<((y + 1) * w) {
                        dst[i] = UInt8(min(max(src[i], 0), 1) * 255 + 0.5)
                    }
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: w, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            throw ImageFileError.cannotSave("cannot create grayscale CGImage")
        }
        return cg
    }

    /// 8-bit sRGB CGImage from a float buffer (for Vision, previews, JPEG export).
    public static func cgImage8(from image: ImageBuffer) throws -> CGImage {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        image.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let pi = (y * w + x) * 4
                        // Premultiply: buffers use alpha 0 for "no data" (warp
                        // out-of-bounds) — render those honestly black.
                        let a = min(max(src[pi + 3], 0), 1)
                        for c in 0..<3 {
                            dst[pi + c] = UInt8(min(max(src[pi + c], 0), 1) * a * 255 + 0.5)
                        }
                        dst[pi + 3] = UInt8(a * 255 + 0.5)
                    }
                }
            }
        }
        let space = workingSpace
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            throw ImageFileError.cannotSave("cannot create 8-bit CGImage")
        }
        return cg
    }

    /// 16-bit sRGB CGImage (big-endian samples, as CGImage expects by default).
    public static func cgImage16(from image: ImageBuffer) throws -> CGImage {
        let w = image.width, h = image.height
        var samples = [UInt16](repeating: 0, count: w * h * 4)
        image.pixels.withUnsafeBufferPointer { src in
            samples.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let pi = (y * w + x) * 4
                        let a = min(max(src[pi + 3], 0), 1)
                        for c in 0..<3 {
                            dst[pi + c] = UInt16(min(max(src[pi + c], 0), 1) * a * 65535 + 0.5).bigEndian
                        }
                        dst[pi + 3] = UInt16(a * 65535 + 0.5).bigEndian
                    }
                }
            }
        }
        let data = samples.withUnsafeBytes { Data($0) }
        let space = workingSpace
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64,
                               bytesPerRow: w * 8, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            throw ImageFileError.cannotSave("cannot create 16-bit CGImage")
        }
        return cg
    }

    // MARK: - Saving

    /// Saves by extension: .tif/.tiff/.png → 16-bit, .jpg/.jpeg → 8-bit,
    /// .dng → 16-bit Linear DNG. Pass a source frame of the stack so its EXIF
    /// (exposure, lens, camera, GPS — and for DNG from raw sources, as-shot
    /// white balance) carries over into the export. `extraProperties` are
    /// ImageIO destination properties merged on top (used by SynthStack to
    /// stamp capture times; ignored for DNG). `colorSpace` converts the export
    /// out of the working space (nil keeps Display P3; DNG always declares P3
    /// and ignores it).
    public static func save(_ image: ImageBuffer, to url: URL,
                            sourceFrame: URL? = nil,
                            extraProperties: [CFString: Any]? = nil,
                            colorSpace: CGColorSpace? = nil) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "dng" {
            try DNGWriter.write(image, to: url, sourceFrame: sourceFrame)
            return
        }
        let type: UTType
        var cg: CGImage
        switch ext {
        case "tif", "tiff":
            type = .tiff
            cg = try cgImage16(from: image)
        case "png":
            type = .png
            cg = try cgImage16(from: image)
        case "jpg", "jpeg":
            type = .jpeg
            cg = try cgImage8(from: image)
        default:
            throw ImageFileError.unsupported("extension .\(ext) (use tif, png, or jpg)")
        }
        if let colorSpace, colorSpace.name != workingSpace.name {
            cg = try convert(cg, to: colorSpace)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageFileError.cannotSave(url.path)
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let sourceFrame, let meta = exportMetadata(from: sourceFrame) {
            props.merge(meta) { current, _ in current }
        }
        if let extraProperties {
            props.merge(extraProperties) { _, extra in extra }
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageFileError.cannotSave(url.path)
        }
    }

    /// Converts a tagged CGImage into another RGB space at the same bit depth
    /// (CoreGraphics converts on draw between tagged spaces).
    static func convert(_ cg: CGImage, to space: CGColorSpace) throws -> CGImage {
        let w = cg.width, h = cg.height
        let bpc = cg.bitsPerComponent >= 16 ? 16 : 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | (bpc == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: bpc, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else {
            throw ImageFileError.cannotSave("cannot create \(bpc)-bit context for color conversion")
        }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let converted = ctx.makeImage() else {
            throw ImageFileError.cannotSave("color conversion failed")
        }
        return converted
    }

    /// EXIF/camera/GPS metadata from a stack frame, filtered for a fused export:
    /// geometry-specific fields (pixel dimensions, orientation) are dropped —
    /// the output is cropped/warped upright and must describe itself.
    static func exportMetadata(from url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any] else { return nil }
        var out: [CFString: Any] = [:]
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            out[kCGImagePropertyExifDictionary] = exif
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var kept: [CFString: Any] = [kCGImagePropertyTIFFSoftware: "Hyperfocal"]
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
                        kCGImagePropertyTIFFDateTime] {
                if let value = tiff[key] { kept[key] = value }
            }
            out[kCGImagePropertyTIFFDictionary] = kept
        }
        if let gps = props[kCGImagePropertyGPSDictionary] {
            out[kCGImagePropertyGPSDictionary] = gps
        }
        return out.isEmpty ? nil : out
    }

#else  // !canImport(CoreGraphics) — Linux/Windows via the CImaging shim.

    // MARK: - Loading

    public static func pixelSize(url: URL) -> (width: Int, height: Int)? {
        var w: CInt = 0, h: CInt = 0
        guard hf_pixel_size(url.path, isRAW(url) ? 1 : 0, &w, &h) == hf_ok else { return nil }
        return (Int(w), Int(h))
    }

    public static func load(url: URL) throws -> ImageBuffer {
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<Float>? = nil
        let status = isRAW(url)
            ? hf_decode_raw(url.path, &w, &h, &ptr)
            : hf_decode(url.path, &w, &h, &ptr)
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.path) (shim status \(status.rawValue))")
        }
        defer { hf_free(ptr) }
        let count = Int(w) * Int(h) * 4
        let pixels = Array(UnsafeBufferPointer(start: ptr, count: count))
        return ImageBuffer(width: Int(w), height: Int(h), pixels: pixels)
    }

    public static func loadRAW(url: URL) throws -> ImageBuffer {
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<Float>? = nil
        let status = hf_decode_raw(url.path, &w, &h, &ptr)
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.lastPathComponent): RAW decode failed (\(status.rawValue))")
        }
        defer { hf_free(ptr) }
        let count = Int(w) * Int(h) * 4
        let pixels = Array(UnsafeBufferPointer(start: ptr, count: count))
        return ImageBuffer(width: Int(w), height: Int(h), pixels: pixels)
    }

    /// 8-bit luminance plane for registration (the portable `GrayImage` seam).
    public static func loadGray8(url: URL) throws -> GrayImage {
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        let status = hf_decode_gray8(url.path, isRAW(url) ? 1 : 0, &w, &h, &ptr)
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.path) (gray decode status \(status.rawValue))")
        }
        defer { hf_free(ptr) }
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: Int(w) * Int(h)))
        return GrayImage(width: Int(w), height: Int(h), pixels: bytes)
    }

    /// Small Float32 RGBA buffer from a `GrayImage`, sampled down — the
    /// registration progress preview (the Apple path takes a `CGImage`; the
    /// portable seam hands back a `GrayImage`).
    public static func previewBuffer(from gray: GrayImage, maxSide: Int) throws -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(gray.width, gray.height)))
        let pw = max(1, Int(Double(gray.width) * scale))
        let ph = max(1, Int(Double(gray.height) * scale))
        var buf = ImageBuffer(width: pw, height: ph)
        gray.pixels.withUnsafeBufferPointer { src in
            buf.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<ph {
                    let sy = min(y * gray.height / ph, gray.height - 1)
                    for x in 0..<pw {
                        let sx = min(x * gray.width / pw, gray.width - 1)
                        let v = Float(src[sy * gray.width + sx]) / 255
                        let di = (y * pw + x) * 4
                        dst[di] = v; dst[di + 1] = v; dst[di + 2] = v; dst[di + 3] = 1
                    }
                }
            }
        }
        return buf
    }

    // MARK: - Saving

    /// Saves by extension: .tif/.tiff/.png → 16-bit, .jpg/.jpeg → 8-bit,
    /// .dng → 16-bit Linear DNG. `colorSpaceName` ("srgb"/"p3"/"prophoto")
    /// converts the export out of the working space (nil keeps Display P3; DNG
    /// always declares P3). `sourceFrame` carries EXIF into a DNG export; for
    /// raster exports EXIF carry-over is not yet wired on this platform.
    public static func save(_ image: ImageBuffer, to url: URL,
                            sourceFrame: URL? = nil,
                            colorSpaceName: String? = nil) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "dng" {
            try DNGWriter.write(image, to: url, sourceFrame: sourceFrame)
            return
        }
        let cs = colorSpaceName ?? "p3"
        let w = CInt(image.width), h = CInt(image.height)
        let status: hf_status = try image.pixels.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress
            switch ext {
            case "tif", "tiff": return hf_encode_tiff16(url.path, w, h, base, cs)
            case "png":         return hf_encode_png16(url.path, w, h, base, cs)
            case "jpg", "jpeg": return hf_encode_jpeg8(url.path, w, h, base, cs)
            default:
                throw ImageFileError.unsupported("extension .\(ext) (use tif, png, or jpg)")
            }
        }
        guard status == hf_ok else {
            throw ImageFileError.cannotSave("\(url.path) (shim status \(status.rawValue))")
        }
    }

#endif
}
