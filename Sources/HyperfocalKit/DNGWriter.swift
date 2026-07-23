import Foundation
import Dispatch
#if canImport(CoreImage)
import CoreImage
import ImageIO
#else
import CImaging
#endif
import CDNGSDK

/// Linear DNG export: demosaiced 16-bit linear RGB with PhotometricInterpretation
/// = LinearRaw, camera space declared as linear Display P3 via ColorMatrix1 with the
/// white point already neutral — so raw processors (Lightroom/ACR) reconstruct
/// correct color and offer raw-grade editing latitude without us inventing
/// camera calibration data.
///
/// Primary path is the vendored Adobe DNG SDK (canonical structure, lossless
/// JPEG compression ≈ half the file size, Adobe-blessed compatibility). The
/// hand-rolled uncompressed writer below is kept as a zero-dependency fallback.
public enum DNGWriter {

    /// Metadata harvested from a source raw frame for propagation into the DNG.
    public struct SourceMetadata {
        public var make: String?
        public var model: String?
        public var lensName: String?
        public var dateTimeOriginal: String?
        public var exposureTime: Double?
        public var fNumber: Double?
        public var focalLengthMM: Double?
        public var iso: Int?
        /// As-shot white chromaticity (CIE xy) from the raw decode —
        /// CIRAWFilter.neutralChromaticity on Apple platforms,
        /// hf_raw_neutral_xy (LibRaw cam_mul through the camera matrix)
        /// elsewhere.
        public var neutralXY: CGPoint?
    }

    /// Reads EXIF + as-shot white balance from a source frame (typically the
    /// first frame of the stack). Header parse only — no pixel decode.
    public static func sourceMetadata(from url: URL) -> SourceMetadata {
        var meta = SourceMetadata()
        #if canImport(CoreImage)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                meta.make = tiff[kCGImagePropertyTIFFMake] as? String
                meta.model = tiff[kCGImagePropertyTIFFModel] as? String
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                meta.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
                meta.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
                meta.focalLengthMM = exif[kCGImagePropertyExifFocalLength] as? Double
                meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
                meta.dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
                meta.lensName = exif[kCGImagePropertyExifLensModel] as? String
            }
        }
        if ImageFile.isRAW(url), let filter = CIRAWFilter(imageURL: url) {
            meta.neutralXY = filter.neutralChromaticity
        }
        #else
        // easyexif reads the same EXIF fields; the as-shot neutral comes from
        // LibRaw's white-balance multipliers via the camera matrix.
        if ImageFile.isRAW(url) {
            var x = 0.0, y = 0.0
            if hf_raw_neutral_xy(url.path, &x, &y) == hf_ok {
                meta.neutralXY = CGPoint(x: x, y: y)
            }
        }
        var nums = hf_exif_numbers()
        let cap = 256
        var make = [CChar](repeating: 0, count: cap)
        var model = [CChar](repeating: 0, count: cap)
        var lens = [CChar](repeating: 0, count: cap)
        var datetime = [CChar](repeating: 0, count: cap)
        _ = hf_exif_source_meta(url.path, &make, cap, &model, cap, &lens, cap,
                                &datetime, cap, &nums)
        func str(_ buf: [CChar]) -> String? {
            let s = String(cString: buf); return s.isEmpty ? nil : s
        }
        meta.make = str(make)
        meta.model = str(model)
        meta.lensName = str(lens)
        meta.dateTimeOriginal = str(datetime)
        if nums.exposure_time.isFinite { meta.exposureTime = nums.exposure_time }
        if nums.f_number.isFinite { meta.fNumber = nums.f_number }
        if nums.focal_length_mm.isFinite { meta.focalLengthMM = nums.focal_length_mm }
        if nums.iso >= 0 { meta.iso = Int(nums.iso) }
        #endif
        return meta
    }

    /// Primary entry point: Adobe DNG SDK, falling back to the hand-rolled
    /// writer if the SDK reports an error. When `sourceFrame` is provided, its
    /// EXIF carries into the DNG; if it's a raw file, the as-shot white balance
    /// is divided back out of the pixels and declared via AsShotNeutral, so raw
    /// processors show the shot's real temperature/tint instead of a generic
    /// neutral.
    public static func write(_ image: ImageBuffer, to url: URL,
                             sourceFrame: URL? = nil) throws {
        let w = image.width, h = image.height
        let meta = sourceFrame.map { sourceMetadata(from: $0) } ?? SourceMetadata()

        // Un-bake white balance. Our pixels are already balanced; a raw
        // processor renders DNG data by *dividing* by AsShotNeutral, so we
        // multiply the balanced data by the neutral (components ≤ 1, hence
        // clip-safe) and the renderer's division recovers it exactly — with
        // the WB sliders now showing the shot's real temperature/tint.
        var neutral: (Double, Double, Double)? = nil
        var channelFactors: (Float, Float, Float)? = nil
        if let xy = meta.neutralXY, xy.y > 0.0001 {
            let X = xy.x / xy.y, Y = 1.0, Z = (1 - xy.x - xy.y) / xy.y
            // Through the same XYZ→camera matrix the profile declares, so the
            // renderer's AsShotNeutral division is exact in camera space.
            let m = xyzToCamera
            var n = (m[0] * X + m[1] * Y + m[2] * Z,
                     m[3] * X + m[4] * Y + m[5] * Z,
                     m[6] * X + m[7] * Y + m[8] * Z)
            let peak = max(n.0, n.1, n.2)
            if peak > 0.0001, min(n.0, n.1, n.2) / peak > 0.05 {
                n = (n.0 / peak, n.1 / peak, n.2 / peak)
                neutral = n
                channelFactors = (Float(n.0), Float(n.1), Float(n.2))
            }
        }

        let rgb = linearRGB16(from: image, channelFactors: channelFactors)

        let scale = 256.0 / Double(max(w, h))
        let pw = max(1, Int(Double(w) * scale)), ph = max(1, Int(Double(h) * scale))
        let preview = Filters.resizeBilinear(image, toWidth: pw, toHeight: ph)
        var previewRGB = [UInt8](repeating: 0, count: pw * ph * 3)
        for i in 0..<(pw * ph) {
            for c in 0..<3 {
                previewRGB[i * 3 + c] =
                    UInt8(min(max(preview.pixels[i * 4 + c], 0), 1) * 255 + 0.5)
            }
        }

        var cMeta = hyperfocal_dng_metadata()
        cMeta.exposureTime = meta.exposureTime ?? 0
        cMeta.fNumber = meta.fNumber ?? 0
        cMeta.focalLengthMM = meta.focalLengthMM ?? 0
        cMeta.isoSpeed = Int32(meta.iso ?? 0)
        if let neutral {
            cMeta.asShotNeutral = (neutral.0, neutral.1, neutral.2)
            cMeta.hasNeutral = 1
        }
        cMeta.baselineExposure = 0

        var errbuf = [CChar](repeating: 0, count: 256)
        let status = withCStrings([meta.make, meta.model, meta.lensName,
                                   meta.dateTimeOriginal]) { strings -> Int32 in
            cMeta.make = strings[0]
            cMeta.model = strings[1]
            cMeta.lensName = strings[2]
            cMeta.dateTimeOriginal = strings[3]
            return rgb.withUnsafeBufferPointer { rgbPtr in
                previewRGB.withUnsafeBufferPointer { prevPtr in
                    withUnsafePointer(to: cMeta) { metaPtr in
                        hyperfocal_write_linear_dng(rgbPtr.baseAddress, Int32(w), Int32(h),
                                                 prevPtr.baseAddress, Int32(pw), Int32(ph),
                                                 url.path, "Hyperfocal Linear DNG",
                                                 metaPtr, &errbuf, Int32(errbuf.count))
                    }
                }
            }
        }
        if status != 0 {
            let message = String(cString: errbuf)
            FileHandle.standardError.write(Data(
                "warning: DNG SDK write failed (\(message)); falling back to uncompressed writer\n".utf8))
            try writeUncompressed(image, to: url)
        }
    }

    /// Runs `body` with stable C-string pointers for the given optional strings
    /// (nil stays nil).
    private static func withCStrings<R>(_ strings: [String?],
                                        _ body: ([UnsafePointer<CChar>?]) -> R) -> R {
        // _strdup is the conformant CRT spelling on Windows; plain strdup
        // there is a deprecation warning.
        #if os(Windows)
        let duped = strings.map { $0.flatMap { _strdup($0) } }
        #else
        let duped = strings.map { $0.flatMap { strdup($0) } }
        #endif
        defer { duped.forEach { $0.map { free($0) } } }
        return body(duped.map { $0.map { UnsafePointer($0) } })
    }

    /// Full-range 16-bit linear RGB from the pipeline's working-space floats
    /// (Display P3 shares the sRGB transfer curve, so the same EOTF applies),
    /// optionally scaling each channel (white-balance un-bake).
    static func linearRGB16(from image: ImageBuffer,
                            channelFactors: (Float, Float, Float)? = nil) -> [UInt16] {
        let w = image.width, h = image.height
        let factors = channelFactors ?? (1, 1, 1)
        let f = [factors.0, factors.1, factors.2]
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        image.pixels.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let si = (y * w + x) * 4
                        let di = (y * w + x) * 3
                        for c in 0..<3 {
                            let v = min(max(src[si + c], 0), 1)
                            let linear: Float = v <= 0.04045
                                ? v / 12.92
                                : powf((v + 0.055) / 1.055, 2.4)
                            dst[di + c] = UInt16(min(linear * f[c], 1) * 65535 + 0.5)
                        }
                    }
                }
            }
        }
        return rgb
    }

    // XYZ (D65) → linear Display P3. In DNG terms: ColorMatrix1 maps XYZ to
    // camera coordinates, and our camera coordinates *are* the pipeline's
    // linear working primaries (Display P3). Must match dng_shim.cpp.
    static let xyzToCamera: [Double] = [
        2.4934969, -0.9313836, -0.4027108,
        -0.8294890, 1.7626641, 0.0236247,
        0.0358458, -0.0761724, 0.9568845,
    ]

    // ForwardMatrix1: white-balanced camera → XYZ (D50), i.e.
    // Bradford(D65→D50) × P3→XYZ(D65) — camera white (1,1,1) lands on D50.
    // Lets ACR render our primaries exactly instead of deriving the mapping
    // from its adaptation heuristics. Must match dng_shim.cpp; if either
    // matrix ever changes after DNGs have been distributed, rename the
    // embedded profile (see the policy note there).
    static let forwardMatrix: [Double] = [
        0.5150749, 0.2919397, 0.1571791,
        0.2411702, 0.6922355, 0.0665900,
        -0.0010486, 0.0418841, 0.7845459,
    ]

    /// Fallback: canonical DNG structure (preview IFD0 + LinearRaw SubIFD)
    /// written by hand, uncompressed.
    public static func writeUncompressed(_ image: ImageBuffer, to url: URL) throws {
        let w = image.width, h = image.height
        precondition(w > 0 && h > 0)

        let rawPayload = linearRGB16(from: image)

        // Preview payload: 8-bit sRGB RGB, longest side ≤ 256.
        let scale = 256.0 / Double(max(w, h))
        let pw = max(1, Int(Double(w) * scale)), ph = max(1, Int(Double(h) * scale))
        let preview = Filters.resizeBilinear(image, toWidth: pw, toHeight: ph)
        var previewPayload = [UInt8](repeating: 0, count: pw * ph * 3)
        for i in 0..<(pw * ph) {
            for c in 0..<3 {
                previewPayload[i * 3 + c] =
                    UInt8(min(max(preview.pixels[i * 4 + c], 0), 1) * 255 + 0.5)
            }
        }

        // Layout: header, preview data, raw data, IFD0 (+values), raw IFD (+values).
        let headerSize = 8
        let previewOffset = UInt32(headerSize)
        var previewSize = previewPayload.count
        previewSize += previewSize % 2  // keep everything even-aligned
        let rawOffset = previewOffset + UInt32(previewSize)

        let bytesPerRow = w * 6
        let rowsPerStrip = max(1, (8 << 20) / bytesPerRow)
        let stripCount = (h + rowsPerStrip - 1) / rowsPerStrip
        var stripOffsets = [UInt32]()
        var stripByteCounts = [UInt32]()
        var cursor = rawOffset
        for s in 0..<stripCount {
            let rows = min(rowsPerStrip, h - s * rowsPerStrip)
            stripOffsets.append(cursor)
            stripByteCounts.append(UInt32(rows * bytesPerRow))
            cursor += UInt32(rows * bytesPerRow)
        }
        let ifd0Offset = cursor

        // Raw SubIFD offset depends on IFD0's total size; entry counts are fixed,
        // so compute both IFDs, then resolve.
        let rawIFDEntries: [Entry] = [
            Entry(tag: 254, value: .long([0])),                     // full-resolution image
            Entry(tag: 256, value: .long([UInt32(w)])),
            Entry(tag: 257, value: .long([UInt32(h)])),
            Entry(tag: 258, value: .short([16, 16, 16])),
            Entry(tag: 259, value: .short([1])),                    // uncompressed
            Entry(tag: 262, value: .short([34892])),                // LinearRaw
            Entry(tag: 273, value: .long(stripOffsets)),
            Entry(tag: 277, value: .short([3])),
            Entry(tag: 278, value: .long([UInt32(rowsPerStrip)])),
            Entry(tag: 279, value: .long(stripByteCounts)),
            Entry(tag: 284, value: .short([1])),                    // chunky
            Entry(tag: 50717, value: .short([65535, 65535, 65535])),// WhiteLevel
        ]

        func ifd0Entries(rawIFDOffset: UInt32) -> [Entry] {
            [
                Entry(tag: 254, value: .long([1])),                 // reduced-res preview
                Entry(tag: 256, value: .long([UInt32(pw)])),
                Entry(tag: 257, value: .long([UInt32(ph)])),
                Entry(tag: 258, value: .short([8, 8, 8])),
                Entry(tag: 259, value: .short([1])),
                Entry(tag: 262, value: .short([2])),                // RGB
                Entry(tag: 273, value: .long([previewOffset])),
                Entry(tag: 277, value: .short([3])),
                Entry(tag: 278, value: .long([UInt32(ph)])),
                Entry(tag: 279, value: .long([UInt32(previewPayload.count)])),
                Entry(tag: 284, value: .short([1])),
                Entry(tag: 305, value: .ascii("hyperfocal")),
                Entry(tag: 330, value: .long([rawIFDOffset])),      // SubIFDs
                Entry(tag: 50706, value: .byte([1, 4, 0, 0])),      // DNGVersion
                Entry(tag: 50707, value: .byte([1, 2, 0, 0])),      // DNGBackwardVersion
                Entry(tag: 50708, value: .ascii("Hyperfocal Linear DNG")),
                Entry(tag: 50721, value: .srational(xyzToCamera.map {
                    (Int32(($0 * 10000).rounded()), Int32(10000))
                })),                                                // ColorMatrix1
                Entry(tag: 50728, value: .rational([(1, 1), (1, 1), (1, 1)])),
                Entry(tag: 50778, value: .short([21])),             // CalibrationIlluminant1: D65
                // Explicit linear ProfileToneCurve + DefaultBlackRender=None:
                // a profile with no tone curve gets ACR's default S-curve and
                // shadow mapping instead of a linear render (see dng_shim.cpp).
                Entry(tag: 50940, value: .float32([0, 0, 0.5, 0.5, 1, 1])),
                Entry(tag: 50964, value: .srational(forwardMatrix.map {
                    (Int32(($0 * 10000).rounded()), Int32(10000))
                })),                                                // ForwardMatrix1
                Entry(tag: 51110, value: .long([1])),               // DefaultBlackRender: None
            ]
        }

        let ifd0Size = encodedIFDSize(ifd0Entries(rawIFDOffset: 0))
        let rawIFDOffset = ifd0Offset + UInt32(ifd0Size)

        var out = Data(capacity: Int(rawIFDOffset) + encodedIFDSize(rawIFDEntries))
        out.append(contentsOf: [0x49, 0x49, 42, 0])                 // "II", magic
        out.appendLE(ifd0Offset)

        previewPayload.withUnsafeBufferPointer { out.append($0.baseAddress!, count: $0.count) }
        if previewPayload.count % 2 == 1 { out.append(0) }

        rawPayload.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: p.count * 2) { bytes in
                out.append(bytes, count: p.count * 2)
            }
        }

        appendIFD(&out, entries: ifd0Entries(rawIFDOffset: rawIFDOffset), at: ifd0Offset)
        appendIFD(&out, entries: rawIFDEntries, at: rawIFDOffset)

        try out.write(to: url)
    }

    // MARK: - TIFF plumbing

    /// Total encoded size of an IFD: count + entries + next-pointer + external
    /// value area (with even-alignment padding).
    static func encodedIFDSize(_ entries: [Entry]) -> Int {
        var external = 0
        for e in entries {
            let raw = e.value.encoded()
            if raw.count > 4 { external += raw.count + raw.count % 2 }
        }
        return 2 + entries.count * 12 + 4 + external
    }

    /// Encode an IFD (entries pre-sorted by tag) whose first byte lands at
    /// `offset` in the file; external values follow the entry table directly.
    static func appendIFD(_ out: inout Data, entries: [Entry], at offset: UInt32) {
        var externalOffset = offset + UInt32(2 + entries.count * 12 + 4)
        var externalData = Data()
        var resolved = entries
        for i in resolved.indices {
            let raw = resolved[i].value.encoded()
            if raw.count > 4 {
                resolved[i].externalOffset = externalOffset
                externalData.append(raw)
                if raw.count % 2 == 1 { externalData.append(0) }
                externalOffset += UInt32(raw.count + raw.count % 2)
            }
        }
        out.appendLE(UInt16(resolved.count))
        for entry in resolved {
            out.appendLE(entry.tag)
            out.appendLE(entry.value.typeCode)
            out.appendLE(entry.value.count)
            if let external = entry.externalOffset {
                out.appendLE(external)
            } else {
                let raw = entry.value.encoded()
                out.append(raw)
                out.append(Data(repeating: 0, count: 4 - raw.count))
            }
        }
        out.appendLE(UInt32(0))  // no next IFD
        out.append(externalData)
    }

    struct Entry {
        let tag: UInt16
        let value: Value
        var externalOffset: UInt32? = nil
    }

    enum Value {
        case byte([UInt8])
        case ascii(String)
        case short([UInt16])
        case long([UInt32])
        case rational([(UInt32, UInt32)])
        case srational([(Int32, Int32)])
        case float32([Float])

        var typeCode: UInt16 {
            switch self {
            case .byte: return 1
            case .ascii: return 2
            case .short: return 3
            case .long: return 4
            case .rational: return 5
            case .srational: return 10
            case .float32: return 11
            }
        }

        var count: UInt32 {
            switch self {
            case .byte(let v): return UInt32(v.count)
            case .ascii(let s): return UInt32(s.utf8.count + 1)  // NUL-terminated
            case .short(let v): return UInt32(v.count)
            case .long(let v): return UInt32(v.count)
            case .rational(let v): return UInt32(v.count)
            case .srational(let v): return UInt32(v.count)
            case .float32(let v): return UInt32(v.count)
            }
        }

        func encoded() -> Data {
            var d = Data()
            switch self {
            case .byte(let v):
                d.append(contentsOf: v)
            case .ascii(let s):
                d.append(contentsOf: Array(s.utf8))
                d.append(0)
            case .short(let v):
                for x in v { d.appendLE(x) }
            case .long(let v):
                for x in v { d.appendLE(x) }
            case .rational(let v):
                for (n, den) in v { d.appendLE(n); d.appendLE(den) }
            case .srational(let v):
                for (n, den) in v { d.appendLE(UInt32(bitPattern: n)); d.appendLE(UInt32(bitPattern: den)) }
            case .float32(let v):
                for x in v { d.appendLE(x.bitPattern) }
            }
            return d
        }
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
