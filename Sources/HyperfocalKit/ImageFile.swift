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

    /// Announces the whole frame list before a stack-wide decode begins.
    ///
    /// Off Apple this lets the raw transcode fallback (`RawConverter`) batch:
    /// when a stack's raws need the Adobe DNG Converter, the first frame to
    /// discover that converts the entire list in one process instead of
    /// relaunching the converter per frame — measured 6x on 45 MP NEFs. No-op
    /// on Apple, where CIRAW decodes these natively and there is no fallback
    /// to batch. Safe and cheap to call more than once per stack: it only
    /// records the list, and the batch itself runs at most once because every
    /// later frame is a cache hit.
    public static func expectStack(urls: [URL]) {
        #if !canImport(CoreGraphics)
        RawConverter.shared.expectStack(urls)
        #endif
    }

    /// A gray plane decoded for registration, possibly at a reduced scale
    /// (JPEG DCT-domain 1/2 or 1/4 on the CImaging path). `decodeFactor` is
    /// full-resolution pixels per gray pixel (1, 2, or 4 — scaled dims are
    /// ceil(full / factor)); registration maps its homographies back to
    /// full-res coordinates through it.
    public struct RegistrationGray {
        public let image: GrayImage
        public let fullWidth: Int
        public let fullHeight: Int
        public let decodeFactor: Int
        /// The full-resolution decode this gray was derived from — populated
        /// **only** when producing the gray required decoding it anyway (RAW on
        /// Apple, where there is no cheap route to luminance) *and* the caller
        /// asked for it. nil everywhere else, and callers must treat nil as the
        /// normal case rather than a failure. Handing it back costs nothing: it
        /// is a retain of a buffer that was already built and was previously
        /// dropped on the floor. See `DecodedFrameCache`.
        public var source: ImageBuffer? = nil
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
        // .RGBAh renders straight into the buffer's own f16 storage: no f32
        // staging allocation (~0.7 GB at 46 MP) and no conversion pass.
        buf.pixels.withUnsafeMutableBytes { ptr in
            ciContext.render(ci, toBitmap: ptr.baseAddress!, rowBytes: w * 8,
                             bounds: extent, format: .RGBAh, colorSpace: space)
        }
        return buf
    }

    /// Bitmap-context layout matching `ImageBuffer`'s storage: 16-bit float
    /// RGBA, premultiplied-last, little-endian — a CoreGraphics-supported
    /// pixel format, so the context draws directly into our pixels.
    static let halfBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue

    /// Decode any CGImage into RGBA half-float via a float bitmap context.
    public static func buffer(from cg: CGImage) throws -> ImageBuffer {
        let w = cg.width, h = cg.height
        var buf = ImageBuffer(width: w, height: h)
        let space = workingSpace
        let ok = buf.pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: space,
                                      bitmapInfo: halfBitmapInfo) else { return false }
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
        try gray8(from: try loadGray8CGImage(url: url))
    }

    /// Registration gray decode on Apple stays full-resolution (Vision's cost
    /// profile never made the scaled decode worth platform churn); the seam
    /// exists so shared Aligner code compiles against one shape. See the
    /// CImaging overload for the reduced-scale semantics.
    /// `wantsSource` asks for the full-resolution decode back alongside the
    /// gray, when making the gray produced one anyway. It never causes a decode
    /// that wouldn't otherwise happen — see `RegistrationGray.source`.
    public static func loadGray8Registration(url: URL, minLongest: Int,
                                             scaleFloorDenom: Int,
                                             wantsSource: Bool = false) throws -> RegistrationGray {
        // RAW has no cheap path to luminance: the gray is derived from a full
        // decode. Keep that decode instead of discarding it — it is bit-for-bit
        // what `load(url:)` would hand fusion later, because both call
        // `loadRAW(url:)` and it is deterministic per file.
        if wantsSource, isRAW(url) {
            let full = try loadRAW(url: url)
            let g = try gray8(from: try grayCGImage8(from: full))
            return RegistrationGray(image: g, fullWidth: g.width, fullHeight: g.height,
                                    decodeFactor: 1, source: full)
        }
        let g = try loadGray8(url: url)
        return RegistrationGray(image: g, fullWidth: g.width, fullHeight: g.height,
                                decodeFactor: 1)
    }

    /// Rasterizes an 8-bit gray CGImage into a `GrayImage` — the tail of
    /// `loadGray8`, split out so the RAW-with-source path above can share it
    /// rather than restate the context setup.
    private static func gray8(from cg: CGImage) throws -> GrayImage {
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

    /// Small RGBA half-float buffer from any CGImage (grayscale included), drawn
    /// at reduced size — cheap progress-preview conversion.
    public static func previewBuffer(from cg: CGImage, maxSide: Int) throws -> ImageBuffer {
        let scale = min(1.0, Double(maxSide) / Double(max(cg.width, cg.height)))
        let pw = max(1, Int(Double(cg.width) * scale))
        let ph = max(1, Int(Double(cg.height) * scale))
        var buf = ImageBuffer(width: pw, height: ph)
        let space = workingSpace
        let ok = buf.pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: pw, height: ph,
                                      bitsPerComponent: 16, bytesPerRow: pw * 8,
                                      space: space,
                                      bitmapInfo: halfBitmapInfo) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            return true
        }
        guard ok else { throw ImageFileError.cannotLoad("cannot create preview context") }
        return buf
    }

    /// Small display thumbnail, favoring the file's embedded preview (RAW
    /// files carry one — extracting it is milliseconds, vs seconds for the
    /// full mosaic decode) and falling back to a reduced decode when a file
    /// has none. Orientation applied. At most `maxSide` on the long edge.
    public static func thumbnail(url: URL, maxSide: Int) throws -> ImageBuffer {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
              ] as CFDictionary) else {
            throw ImageFileError.cannotLoad(
                "cannot extract thumbnail from \(url.lastPathComponent)")
        }
        return try previewBuffer(from: cg, maxSide: maxSide)
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
        image.pixels.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            bytes.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let pi = (y * w + x) * 4
                        let p = hfLoadRGBA(src, pi)
                        // Premultiply: buffers use alpha 0 for "no data" (warp
                        // out-of-bounds) — render those honestly black.
                        let a = min(max(p.w, 0), 1)
                        for c in 0..<3 {
                            dst[pi + c] = UInt8(min(max(p[c], 0), 1) * a * 255 + 0.5)
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
        image.pixels.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            samples.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let pi = (y * w + x) * 4
                        let p = hfLoadRGBA(src, pi)
                        let a = min(max(p.w, 0), 1)
                        for c in 0..<3 {
                            dst[pi + c] = UInt16(min(max(p[c], 0), 1) * a * 65535 + 0.5).bigEndian
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
    /// white balance) carries over into the export. `dateTimeOriginal` stamps an
    /// EXIF capture time ("YYYY:MM:DD HH:MM:SS" — `StackSplitter.exifFormatter`);
    /// used by SynthStack to make synth stacks splittable, ignored for DNG.
    /// `colorSpace` converts the export out of the working space (nil keeps
    /// Display P3; DNG always declares P3 and ignores it). `dngPreviewTone`
    /// is DNG-only: the raw data stays linear, but the embedded preview bakes
    /// this tone so thumbnails match the look the DNG's XMP carries.
    public static func save(_ image: ImageBuffer, to url: URL,
                            sourceFrame: URL? = nil,
                            dateTimeOriginal: String? = nil,
                            colorSpace: CGColorSpace? = nil,
                            dngPreviewTone: ToneSettings = ToneSettings()) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "dng" {
            try DNGWriter.write(image, to: url, sourceFrame: sourceFrame,
                                previewTone: dngPreviewTone)
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
        if let dateTimeOriginal {
            var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = dateTimeOriginal
            props[kCGImagePropertyExifDictionary] = exif
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
        if isRAW(url) { return try decodeRawRGBA(url) }
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<Float>? = nil
        let status = hf_decode(url.path, &w, &h, &ptr)
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.path) (shim status \(status.rawValue))")
        }
        defer { hf_free(ptr) }
        return ImageBuffer(width: Int(w), height: Int(h), floatPixels: ptr)
    }

    /// No embedded-preview extraction on the CImaging path yet (LibRaw's
    /// unpack_thumb would be the upgrade) — decode and downsample. Slow for
    /// RAW, but stack thumbnails generate once, in the background, and cache.
    public static func thumbnail(url: URL, maxSide: Int) throws -> ImageBuffer {
        try load(url: url).downsampledNearest(maxSide: maxSide)
    }

    public static func loadRAW(url: URL) throws -> ImageBuffer {
        try decodeRawRGBA(url)
    }

    /// Decodes a raw file to RGBA via the shim, transparently falling back to an
    /// Adobe-DNG-Converter transcode when the shim reports the pixel format
    /// unsupported (`hf_err_format` — Nikon High-Efficiency NEFs, or a camera
    /// newer than the installed LibRaw). The DNG is cached, so this converts once
    /// per source across every decode path.
    private static func decodeRawRGBA(_ url: URL) throws -> ImageBuffer {
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<Float>? = nil
        var status = hf_decode_raw(url.path, &w, &h, &ptr)
        if status == hf_err_format {
            let dng = try RawConverter.shared.convertedDNG(for: url)
            status = hf_decode_raw(dng.path, &w, &h, &ptr)
        }
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.lastPathComponent): RAW decode failed (\(status.rawValue))")
        }
        defer { hf_free(ptr) }
        return ImageBuffer(width: Int(w), height: Int(h), floatPixels: ptr)
    }

    /// 8-bit luminance plane for registration (the portable `GrayImage` seam).
    public static func loadGray8(url: URL) throws -> GrayImage {
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        var status = hf_decode_gray8(url.path, isRAW(url) ? 1 : 0, &w, &h, &ptr)
        if status == hf_err_format, isRAW(url) {
            let dng = try RawConverter.shared.convertedDNG(for: url)
            status = hf_decode_gray8(dng.path, 1, &w, &h, &ptr)
        }
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.path) (gray decode status \(status.rawValue))")
        }
        defer { hf_free(ptr) }
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: Int(w) * Int(h)))
        return GrayImage(width: Int(w), height: Int(h), pixels: bytes)
    }

    /// Registration gray decode: JPEGs come back at the largest DCT-domain
    /// reduction (1/2 or 1/4) whose longest side stays >= max(minLongest,
    /// full / scaleFloorDenom) — most of the IDCT is skipped, and gradient/
    /// stats/SIFT all run on 1/4 to 1/16 the pixels. Other formats decode
    /// full-resolution (decodeFactor 1). HYPERFOCAL_REGISTER_FULLGRAY=1
    /// disables the reduction for A/B isolation.
    /// `wantsSource` is accepted and ignored here: this path decodes gray
    /// directly (LibRaw / libjpeg, often at a reduced scale) and never
    /// materializes an RGBA buffer, so there is nothing already-paid-for to
    /// hand back. Producing one would be extra work, which is precisely what
    /// `DecodedFrameCache` refuses to do.
    public static func loadGray8Registration(url: URL, minLongest: Int,
                                             scaleFloorDenom: Int,
                                             wantsSource: Bool = false) throws -> RegistrationGray {
        let disabled = ProcessInfo.processInfo
            .environment["HYPERFOCAL_REGISTER_FULLGRAY"] == "1"
        var fw: CInt = 0, fh: CInt = 0, denom: CInt = 0
        var w: CInt = 0, h: CInt = 0
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        var status = hf_decode_gray8_scaled(url.path, isRAW(url) ? 1 : 0,
                                            disabled ? 0 : CInt(minLongest),
                                            CInt(scaleFloorDenom),
                                            &fw, &fh, &denom, &w, &h, &ptr)
        if status == hf_err_format, isRAW(url) {
            let dng = try RawConverter.shared.convertedDNG(for: url)
            status = hf_decode_gray8_scaled(dng.path, 1,
                                            disabled ? 0 : CInt(minLongest),
                                            CInt(scaleFloorDenom),
                                            &fw, &fh, &denom, &w, &h, &ptr)
        }
        guard status == hf_ok, let ptr, w > 0, h > 0 else {
            throw ImageFileError.cannotLoad("\(url.path) (gray decode status \(status.rawValue))")
        }
        defer { hf_free(ptr) }
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: Int(w) * Int(h)))
        return RegistrationGray(image: GrayImage(width: Int(w), height: Int(h), pixels: bytes),
                                fullWidth: Int(fw), fullHeight: Int(fh),
                                decodeFactor: Int(denom))
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
            buf.pixels.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                for y in 0..<ph {
                    let sy = min(y * gray.height / ph, gray.height - 1)
                    for x in 0..<pw {
                        let sx = min(x * gray.width / pw, gray.width - 1)
                        let v = Float(src[sy * gray.width + sx]) / 255
                        hfStoreRGBA(dst, (y * pw + x) * 4, SIMD4<Float>(v, v, v, 1))
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
    /// `dateTimeOriginal` stamps an EXIF capture time ("YYYY:MM:DD HH:MM:SS" —
    /// `StackSplitter.exifFormatter`); TIFF only, matching where SynthStack
    /// needs it, and ignored for DNG. `dngPreviewTone` is DNG-only: the raw
    /// data stays linear, but the embedded preview bakes this tone so
    /// thumbnails match the look the DNG's XMP carries.
    public static func save(_ image: ImageBuffer, to url: URL,
                            sourceFrame: URL? = nil,
                            dateTimeOriginal: String? = nil,
                            colorSpaceName: String? = nil,
                            dngPreviewTone: ToneSettings = ToneSettings()) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "dng" {
            try DNGWriter.write(image, to: url, sourceFrame: sourceFrame,
                                previewTone: dngPreviewTone)
            return
        }
        let cs = colorSpaceName ?? "p3"
        let w = CInt(image.width), h = CInt(image.height)
        // The encoders' C ABI is `const float*`; this is one of the few places
        // that genuinely materializes an f32 copy of the plane.
        let status: hf_status = try image.floatPixels().withUnsafeBufferPointer { buf in
            let base = buf.baseAddress
            switch ext {
            case "tif", "tiff": return hf_encode_tiff16(url.path, w, h, base, cs, dateTimeOriginal)
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
