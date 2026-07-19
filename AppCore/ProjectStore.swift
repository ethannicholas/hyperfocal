import Foundation
#if canImport(simd)
import simd
#endif
#if canImport(zlib)
import zlib
#else
import CZlib
#endif
import HyperfocalKit

/// Serializes a project to a single zip file (Name.hyperfocal): a JSON
/// manifest plus 16-bit raw blobs per fused stack (pixels as UInt16, depth as
/// 1/64-index fixed point — frame counts up to ~1000 — sharpness scaled to its
/// global max). Pixel data is embedded because retouch edits cannot be
/// recomputed; alignment transforms are embedded so retouch sources and
/// re-fuses work immediately after restore.
///
/// The container is a store-only (uncompressed) zip: deflate on 16-bit image
/// data is slow for little gain, and stored entries make saves exactly as
/// fast as loose files while keeping the project one pickable, mailable,
/// syncable file. Zip64 structures are always written so multi-gigabyte
/// projects don't silently corrupt at the 4 GB line.
///
/// v3 (multi-stack): `manifest.json` holds a stacks array; each fused stack's
/// blobs live under `stack_NNN/`.
enum ProjectStore {

    static let fileExtension = "hyperfocal"
    static let formatVersion = 3

    struct Manifest: Codable {
        var version: Int
        // Working color space of the raw pixel blobs (absent = the pre-P3
        // sRGB era). Mismatches are refused at read, not silently reinterpreted.
        var colorSpace: String?
        var selectedIndex: Int?
        // Security-scoped bookmarks keyed by granted-root path (stack folders,
        // or single frames when only files were granted). Sandboxed builds
        // resolve these to regain frame access after relaunch; paths remain
        // the source of truth and non-sandboxed builds ignore them.
        var bookmarks: [String: Data]?
        var stacks: [StackManifest]
    }

    struct StackManifest: Codable {
        var name: String
        var enabled: Bool
        var framePaths: [String]
        var includedPaths: [String]
        var transforms: [[Float]]?       // 9 floats per frame, column-major
        var hasResult: Bool
        var resultWidth: Int
        var resultHeight: Int
        var hasWorking: Bool             // retouch edits present
        var sourceIndex: Int?
        var gains: [Float]?              // legacy luminance gains (pre-per-channel
                                         // files, and written for old readers)
        var gainsRGB: [[Float]]? = nil   // per-channel gains, 3 floats per frame
        var orderWarning: String? = nil  // load-time frame-order sanity warning
        var fusedSettings: FuseSettings? // staleness tracking for Fuse buttons
        var tone: ToneSettings? = nil    // nil = neutral (and pre-tone files)
        var crop: [Int]? = nil           // x, y, w, h in result pixels; nil = uncropped
        var cropAngle: Double? = nil     // degrees about the rect center
        var sharpnessFactor: Int?
        var sharpnessFullWidth: Int?
        var sharpnessFullHeight: Int?
        var sharpnessFrameCount: Int?
        var sharpnessScale: Float?       // global max used for 16-bit quantization
    }

    private struct VersionProbe: Codable {
        var version: Int
        var colorSpace: String?
    }

    struct StackPayload {
        var name: String
        var enabled: Bool = true
        var frameURLs: [URL]
        var includedURLs: Set<URL>
        var transforms: [simd_float3x3]?
        var result: ImageBuffer?         // nil = unfused stack
        var depth: [Float] = []
        var sharpness: FrameSharpness?
        var working: ImageBuffer?        // retouched pixels, if any edits
        var sourceIndex: Int?
        var gains: [SIMD3<Float>]? = nil
        var orderWarning: String? = nil
        var fusedSettings: FuseSettings? = nil
        var tone: ToneSettings? = nil
        var crop: [Int]? = nil           // x, y, w, h in result pixels
        var cropAngle: Double? = nil
    }

    struct Project {
        var stacks: [StackPayload]
        var selectedIndex: Int? = nil
        var bookmarks: [String: Data]? = nil
    }

    /// Where earlier builds autosaved on quit. Kept only so launch can delete
    /// a leftover file (the write was too slow; quit warns instead now).
    static var autosaveURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Hyperfocal/Autosave.\(fileExtension)")
    }

    // MARK: - Write

    static func write(_ project: Project, to url: URL) throws {
        let fm = FileManager.default
        // Stage the file in a temp directory the sandbox can write. The
        // save panel's grant covers exactly the chosen URL — a sibling
        // ".name.tmp" is denied everywhere outside the container, which
        // broke every save. .itemReplacementDirectory returns a writable
        // location on the *destination's* volume (so the final swap is a
        // rename, never a copy); the app's own temp dir is the fallback
        // for volumes that can't provide one.
        let stagingRoot = (try? fm.url(for: .itemReplacementDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: url, create: true))
            ?? fm.temporaryDirectory
        let temp = stagingRoot.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: temp)
        defer { try? fm.removeItem(at: temp) }
        let zip = try ZipWriter(url: temp)

        var stackManifests = [StackManifest]()
        for (index, stack) in project.stacks.enumerated() {
            var manifest = StackManifest(
                name: stack.name,
                enabled: stack.enabled,
                framePaths: stack.frameURLs.map(\.path),
                includedPaths: stack.includedURLs.map(\.path),
                transforms: stack.transforms.map { list in
                    list.map { m in
                        (0..<3).flatMap { col in (0..<3).map { row in m[col][row] } }
                    }
                },
                hasResult: stack.result != nil,
                resultWidth: stack.result?.width ?? 0,
                resultHeight: stack.result?.height ?? 0,
                hasWorking: stack.working != nil,
                sourceIndex: stack.sourceIndex,
                // Legacy field carries the luminance combination so pre-
                // per-channel readers still normalize brightness.
                gains: stack.gains.map { $0.map(DMapFusion.luma) },
                gainsRGB: stack.gains.map { $0.map { [$0.x, $0.y, $0.z] } },
                orderWarning: stack.orderWarning,
                fusedSettings: stack.fusedSettings,
                tone: stack.tone,
                crop: stack.crop,
                cropAngle: stack.cropAngle)
            if let result = stack.result {
                let dir = stackDirectoryName(index)
                // All blobs are 16-bit: the pixels came from 16-bit sensors and
                // export at 16-bit, depth is a frame index (1/64-index fixed
                // point), and sharpness only needs relative magnitude.
                try zip.add("\(dir)/result.raw", fixed16Data(result.pixels, scale: 65535))
                try zip.add("\(dir)/depth.raw", fixed16Data(stack.depth, scale: 64))
                if let working = stack.working {
                    try zip.add("\(dir)/working.raw",
                                fixed16Data(working.pixels, scale: 65535))
                }
                if let sharpness = stack.sharpness {
                    var flat = [Float]()
                    flat.reserveCapacity(sharpness.planes.count
                                         * (sharpness.planes.first?.count ?? 0))
                    for plane in sharpness.planes { flat.append(contentsOf: plane) }
                    let scale = max(flat.max() ?? 0, 1e-9)
                    try zip.add("\(dir)/sharpness.raw",
                                fixed16Data(flat, scale: 65535 / scale))
                    manifest.sharpnessFactor = sharpness.factor
                    manifest.sharpnessFullWidth = sharpness.fullWidth
                    manifest.sharpnessFullHeight = sharpness.fullHeight
                    manifest.sharpnessFrameCount = sharpness.planes.count
                    manifest.sharpnessScale = scale
                }
            }
            stackManifests.append(manifest)
        }

        let manifest = Manifest(version: formatVersion,
                                colorSpace: ImageFile.workingSpaceName,
                                selectedIndex: project.selectedIndex,
                                bookmarks: project.bookmarks,
                                stacks: stackManifests)
        try zip.add("manifest.json", JSONEncoder().encode(manifest))
        try zip.finish()

        // Atomic swap: the existing project is only replaced by a fully
        // staged new one (the old delete-then-move destroyed the previous
        // save if the move failed).
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    /// Per-channel gains from a manifest: `gainsRGB` when present, else the
    /// legacy scalar `gains` expanded to equal channels (pre-per-channel
    /// files). Separated so the probe can exercise the legacy path without
    /// hand-building an old archive.
    static func gains(from manifest: StackManifest) -> [SIMD3<Float>]? {
        manifest.gainsRGB.map {
            $0.map { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2])
                                   : SIMD3(repeating: 1) }
        } ?? manifest.gains.map { $0.map { SIMD3(repeating: $0) } }
    }

    private static func stackDirectoryName(_ index: Int) -> String {
        String(format: "stack_%03d", index)
    }

    // MARK: - Read

    static func read(from url: URL) throws -> Project {
        let zip = try ZipReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
        let manifestData = try zip.blob("manifest.json")
        let probe = try JSONDecoder().decode(VersionProbe.self, from: manifestData)
        let space = probe.colorSpace ?? "srgb"
        guard space == ImageFile.workingSpaceName else {
            throw NSError(domain: "Hyperfocal", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "Project was saved in the \(space) working space; this build works in \(ImageFile.workingSpaceName). Re-fuse from the original frames."])
        }
        switch probe.version {
        case formatVersion:
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            let stacks = try manifest.stacks.enumerated().map { index, stack in
                try readStack(stack) { try zip.blob("\(stackDirectoryName(index))/\($0)") }
            }
            return Project(stacks: stacks, selectedIndex: manifest.selectedIndex,
                           bookmarks: manifest.bookmarks)
        default:
            throw NSError(domain: "Hyperfocal", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported session version \(probe.version)"])
        }
    }

    private static func readStack(_ manifest: StackManifest,
                                  blob: (String) throws -> Data) throws -> StackPayload {
        var payload = StackPayload(
            name: manifest.name,
            enabled: manifest.enabled,
            frameURLs: manifest.framePaths.map { URL(fileURLWithPath: $0) },
            includedURLs: Set(manifest.includedPaths.map { URL(fileURLWithPath: $0) }),
            transforms: manifest.transforms.map { list in
                list.map { flat in
                    simd_float3x3(columns: (
                        SIMD3<Float>(flat[0], flat[1], flat[2]),
                        SIMD3<Float>(flat[3], flat[4], flat[5]),
                        SIMD3<Float>(flat[6], flat[7], flat[8])))
                }
            },
            result: nil,
            sourceIndex: manifest.sourceIndex,
            gains: gains(from: manifest),
            orderWarning: manifest.orderWarning,
            fusedSettings: manifest.fusedSettings,
            tone: manifest.tone,
            crop: manifest.crop,
            cropAngle: manifest.cropAngle)
        guard manifest.hasResult else { return payload }

        let w = manifest.resultWidth, h = manifest.resultHeight
        let resultPixels = try readFixed16(try blob("result.raw"), name: "result.raw",
                                           scale: 65535, expected: w * h * 4)
        payload.result = ImageBuffer(width: w, height: h, pixels: resultPixels)
        payload.depth = try readFixed16(try blob("depth.raw"), name: "depth.raw",
                                        scale: 64, expected: w * h)
        if manifest.hasWorking {
            let pixels = try readFixed16(try blob("working.raw"), name: "working.raw",
                                         scale: 65535, expected: w * h * 4)
            payload.working = ImageBuffer(width: w, height: h, pixels: pixels)
        }
        if let factor = manifest.sharpnessFactor,
           let fullW = manifest.sharpnessFullWidth,
           let fullH = manifest.sharpnessFullHeight,
           let count = manifest.sharpnessFrameCount, count > 0 {
            let planeSize = ((fullW + factor - 1) / factor) * ((fullH + factor - 1) / factor)
            let scale = manifest.sharpnessScale ?? 1
            let flat = try readFixed16(try blob("sharpness.raw"), name: "sharpness.raw",
                                       scale: 65535 / max(scale, 1e-9),
                                       expected: planeSize * count)
            let planes = (0..<count).map {
                Array(flat[($0 * planeSize)..<(($0 + 1) * planeSize)])
            }
            payload.sharpness = FrameSharpness(fullWidth: fullW, fullHeight: fullH,
                                               factor: factor, planes: planes)
        }
        return payload
    }

    // MARK: - Blobs

    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Fixed-point 16-bit encoding: stored = round(value * scale).
    private static func fixed16Data(_ values: [Float], scale: Float) -> Data {
        var samples = [UInt16](repeating: 0, count: values.count)
        let chunks = max(1, values.count / 65536)
        values.withUnsafeBufferPointer { src in
            samples.withUnsafeMutableBufferPointer { dst in
                let s = UncheckedSendable(src), d = UncheckedSendable(dst)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let src = s.value, dst = d.value
                    let lo = chunk * src.count / chunks
                    let hi = (chunk + 1) * src.count / chunks
                    for i in lo..<hi {
                        dst[i] = UInt16(min(max(src[i] * scale, 0), 65535) + 0.5)
                    }
                }
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private static func readFixed16(_ data: Data, name: String, scale: Float,
                                    expected: Int) throws -> [Float] {
        guard data.count == expected * 2 else {
            throw NSError(domain: "Hyperfocal", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(name): expected \(expected * 2) bytes, found \(data.count)"])
        }
        var values = [Float](repeating: 0, count: expected)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt16.self)
            let chunks = max(1, expected / 65536)
            values.withUnsafeMutableBufferPointer { dst in
                let s = UncheckedSendable(src), d = UncheckedSendable(dst)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let src = s.value, dst = d.value
                    let lo = chunk * expected / chunks
                    let hi = (chunk + 1) * expected / chunks
                    for i in lo..<hi {
                        dst[i] = Float(src[i]) / scale
                    }
                }
            }
        }
        return values
    }

    // MARK: - Zip container

    /// Store-only zip writer, streamed to disk through a FileHandle. Zip64
    /// sizes/offsets are written unconditionally: projects routinely carry
    /// multi-hundred-MB blobs and multi-stack files cross 4 GB, and one code
    /// path beats two. Entry names are ASCII by construction.
    private final class ZipWriter {
        private let handle: FileHandle
        private var offset: UInt64 = 0
        private var central = Data()
        private var entryCount: UInt64 = 0
        private let dosTime: (time: UInt16, date: UInt16)

        init(url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw NSError(domain: "Hyperfocal", code: 4, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create \(url.lastPathComponent)"])
            }
            handle = try FileHandle(forWritingTo: url)
            let c = Calendar(identifier: .gregorian)
                .dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
            dosTime = (
                time: UInt16((c.hour! << 11) | (c.minute! << 5) | (c.second! / 2)),
                date: UInt16(((max(c.year!, 1980) - 1980) << 9) | (c.month! << 5) | c.day!))
        }

        func add(_ name: String, _ payload: Data) throws {
            let crc = payload.withUnsafeBytes { buf -> UInt32 in
                guard var p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return UInt32(crc32(0, nil, 0))
                }
                var c = crc32(0, nil, 0)
                var remaining = buf.count
                while remaining > 0 {  // crc32 takes a 32-bit length
                    let n = min(remaining, 1 << 30)
                    c = crc32(c, p, uInt(n))
                    p += n
                    remaining -= n
                }
                return UInt32(c)
            }
            let nameBytes = Array(name.utf8)
            let size = UInt64(payload.count)
            // The blobs are read back as zero-copy UInt16 views of the mapped
            // file, so every payload must start 2-aligned; a 5-byte unknown-id
            // extra field flips the parity when the header would land odd.
            let pad = (offset + UInt64(30 + nameBytes.count + 20)) % 2 == 1

            var local = Data()
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(45))              // version needed: zip64
            local.appendLE(UInt16(0))               // flags
            local.appendLE(UInt16(0))               // method: store
            local.appendLE(dosTime.time)
            local.appendLE(dosTime.date)
            local.appendLE(crc)
            local.appendLE(UInt32(0xFFFFFFFF))      // sizes live in zip64 extra
            local.appendLE(UInt32(0xFFFFFFFF))
            local.appendLE(UInt16(nameBytes.count))
            local.appendLE(UInt16(pad ? 25 : 20))   // extra length
            local.append(contentsOf: nameBytes)
            local.appendLE(UInt16(1))               // zip64 extra field
            local.appendLE(UInt16(16))
            local.appendLE(size)                    // uncompressed
            local.appendLE(size)                    // compressed (= stored)
            if pad {
                local.appendLE(UInt16(0x7061))      // alignment pad, skipped by id
                local.appendLE(UInt16(1))
                local.append(0)
            }
            try handle.write(contentsOf: local)
            try handle.write(contentsOf: payload)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(45))            // version made by
            central.appendLE(UInt16(45))            // version needed
            central.appendLE(UInt16(0))             // flags
            central.appendLE(UInt16(0))             // method
            central.appendLE(dosTime.time)
            central.appendLE(dosTime.date)
            central.appendLE(crc)
            central.appendLE(UInt32(0xFFFFFFFF))
            central.appendLE(UInt32(0xFFFFFFFF))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(28))            // extra length
            central.appendLE(UInt16(0))             // comment length
            central.appendLE(UInt16(0))             // disk
            central.appendLE(UInt16(0))             // internal attrs
            central.appendLE(UInt32(0))             // external attrs
            central.appendLE(UInt32(0xFFFFFFFF))    // offset lives in zip64 extra
            central.append(contentsOf: nameBytes)
            central.appendLE(UInt16(1))             // zip64 extra field
            central.appendLE(UInt16(24))
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(offset)                // local header offset

            offset += UInt64(local.count) + size
            entryCount += 1
        }

        func finish() throws {
            var tail = central
            let centralOffset = offset
            let centralSize = UInt64(central.count)

            tail.appendLE(UInt32(0x06064b50))       // zip64 end of central directory
            tail.appendLE(UInt64(44))               // size of remaining record
            tail.appendLE(UInt16(45))
            tail.appendLE(UInt16(45))
            tail.appendLE(UInt32(0))                // this disk
            tail.appendLE(UInt32(0))                // central directory disk
            tail.appendLE(entryCount)
            tail.appendLE(entryCount)
            tail.appendLE(centralSize)
            tail.appendLE(centralOffset)

            tail.appendLE(UInt32(0x07064b50))       // zip64 EOCD locator
            tail.appendLE(UInt32(0))
            tail.appendLE(centralOffset + centralSize)
            tail.appendLE(UInt32(1))                // total disks

            tail.appendLE(UInt32(0x06054b50))       // classic EOCD, all deferred
            tail.appendLE(UInt16(0))
            tail.appendLE(UInt16(0))
            tail.appendLE(UInt16(0xFFFF))
            tail.appendLE(UInt16(0xFFFF))
            tail.appendLE(UInt32(0xFFFFFFFF))
            tail.appendLE(UInt32(0xFFFFFFFF))
            tail.appendLE(UInt16(0))                // comment length

            try handle.write(contentsOf: tail)
            try handle.close()
        }
    }

    /// Reads the central directory of a (possibly zip64) zip and exposes
    /// entries as zero-copy slices of the mapped file. Store-only: entries
    /// compressed by other tools are rejected, not silently misread. CRCs
    /// are not verified — every blob is length-checked, and reads already
    /// touch every byte.
    private struct ZipReader {
        private let data: Data
        private let ranges: [String: Range<Int>]

        init(data: Data) throws {
            self.data = data
            func fail(_ reason: String) -> NSError {
                NSError(domain: "Hyperfocal", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Not a Hyperfocal project (\(reason))"])
            }
            func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
            func u32(_ o: Int) -> UInt64 {
                UInt64(u16(o)) | UInt64(u16(o + 2)) << 16
            }
            func u64(_ o: Int) -> UInt64 { u32(o) | u32(o + 4) << 32 }

            // EOCD: scan back over a possible (foreign) trailing comment.
            guard data.count >= 22 else { throw fail("truncated") }
            var eocd = -1
            var probe = data.count - 22
            let floor = max(0, data.count - 22 - 65535)
            while probe >= floor {
                if u32(probe) == 0x06054b50 { eocd = probe; break }
                probe -= 1
            }
            guard eocd >= 0 else { throw fail("no zip directory") }

            var count = UInt64(u16(eocd + 10))
            var centralOffset = u32(eocd + 16)
            if count == 0xFFFF || centralOffset == 0xFFFFFFFF {
                // Zip64: locator sits directly before the EOCD.
                let locator = eocd - 20
                guard locator >= 0, u32(locator) == 0x07064b50 else {
                    throw fail("bad zip64 locator")
                }
                let record = Int(u64(locator + 8))
                guard record + 56 <= eocd, u32(record) == 0x06064b50 else {
                    throw fail("bad zip64 directory")
                }
                count = u64(record + 32)
                centralOffset = u64(record + 48)
            }

            var entries = [String: Range<Int>]()
            var cursor = Int(centralOffset)
            for _ in 0..<count {
                guard cursor + 46 <= data.count, u32(cursor) == 0x02014b50 else {
                    throw fail("bad directory entry")
                }
                let method = u16(cursor + 10)
                var size = u32(cursor + 24)
                let nameLen = u16(cursor + 28)
                let extraLen = u16(cursor + 30)
                let commentLen = u16(cursor + 32)
                var localOffset = u32(cursor + 42)
                guard cursor + 46 + nameLen + extraLen <= data.count else {
                    throw fail("truncated directory")
                }
                let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLen)],
                                  as: UTF8.self)
                // Zip64 extra field carries whichever values are deferred, in
                // order: uncompressed size, compressed size, offset.
                var extra = cursor + 46 + nameLen
                let extraEnd = extra + extraLen
                while extra + 4 <= extraEnd {
                    let id = u16(extra), len = u16(extra + 2)
                    if id == 1 {
                        var field = extra + 4
                        if size == 0xFFFFFFFF { size = u64(field); field += 8 }
                        if u32(cursor + 20) == 0xFFFFFFFF { field += 8 }  // compressed
                        if localOffset == 0xFFFFFFFF { localOffset = u64(field) }
                    }
                    extra += 4 + len
                }
                guard method == 0 else { throw fail("compressed entry \(name)") }
                // Data begins after the local header's own (independently
                // sized) name and extra fields.
                let lh = Int(localOffset)
                guard lh + 30 <= data.count, u32(lh) == 0x04034b50 else {
                    throw fail("bad local header for \(name)")
                }
                let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
                guard start + Int(size) <= data.count else {
                    throw fail("truncated entry \(name)")
                }
                entries[name] = start..<(start + Int(size))
                cursor += 46 + nameLen + extraLen + commentLen
            }
            ranges = entries
        }

        func blob(_ name: String) throws -> Data {
            guard let range = ranges[name] else {
                throw NSError(domain: "Hyperfocal", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(name): missing from project"])
            }
            // Even offsets (all of ours, by construction) slice the mapping
            // zero-copy; odd ones — possible in a foreign zip — are copied so
            // the 16-bit blob views stay aligned.
            return range.lowerBound % 2 == 0 ? data[range] : data.subdata(in: range)
        }
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }
    mutating func appendLE(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((v >> shift) & 0xFF))
        }
    }
    mutating func appendLE(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((v >> shift) & 0xFF))
        }
    }
}
