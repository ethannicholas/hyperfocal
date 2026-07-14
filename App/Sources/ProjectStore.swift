import Foundation
import simd
import HyperfocalKit

/// Serializes a project to a directory bundle (Name.hyperfocal): a JSON
/// manifest plus 16-bit raw blobs per fused stack (pixels as UInt16, depth as
/// 1/64-index fixed point — frame counts up to ~1000 — sharpness scaled to its
/// global max). Pixel data is embedded because retouch edits cannot be
/// recomputed; alignment transforms are embedded so retouch sources and
/// re-fuses work immediately after restore.
///
/// v3 (multi-stack): `manifest.json` holds a stacks array; each fused stack's
/// blobs live in `stack_NNN/`. v2 single-stack bundles (blobs at the root)
/// still open, as a one-stack project.
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
        var gains: [Float]?              // exposure gains the fusion applied
        var slabPaths: [String]?         // slab images (slabbed fusions)
        var slabFrameGains: [Float]?     // gains baked into the slabs
        var fusedSettings: FuseSettings? // staleness tracking for Fuse buttons
        var tone: ToneSettings? = nil    // nil = neutral (and pre-tone files)
        var sharpnessFactor: Int?
        var sharpnessFullWidth: Int?
        var sharpnessFullHeight: Int?
        var sharpnessFrameCount: Int?
        var sharpnessScale: Float?       // global max used for 16-bit quantization
    }

    /// Legacy single-stack manifest (v2); blobs at the bundle root.
    private struct ManifestV2: Codable {
        var version: Int
        var framePaths: [String]
        var includedPaths: [String]
        var transforms: [[Float]]?
        var resultWidth: Int
        var resultHeight: Int
        var hasWorking: Bool
        var sourceIndex: Int?
        var gains: [Float]?
        var slabPaths: [String]?
        var slabFrameGains: [Float]?
        var bookmarks: [String: Data]?
        var colorSpace: String?
        var sharpnessFactor: Int?
        var sharpnessFullWidth: Int?
        var sharpnessFullHeight: Int?
        var sharpnessFrameCount: Int?
        var sharpnessScale: Float?
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
        var gains: [Float]? = nil
        var slabPaths: [String]? = nil
        var slabFrameGains: [Float]? = nil
        var fusedSettings: FuseSettings? = nil
        var tone: ToneSettings? = nil
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
        // Stage the bundle in a temp directory the sandbox can write. The
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
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

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
                gains: stack.gains,
                slabPaths: stack.slabPaths,
                slabFrameGains: stack.slabFrameGains,
                fusedSettings: stack.fusedSettings,
                tone: stack.tone)
            if let result = stack.result {
                let dir = temp.appendingPathComponent(stackDirectoryName(index))
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                // All blobs are 16-bit: the pixels came from 16-bit sensors and
                // export at 16-bit, depth is a frame index (1/64-index fixed
                // point), and sharpness only needs relative magnitude.
                try writeUnit16(result.pixels, to: dir.appendingPathComponent("result.raw"))
                try writeFixed16(stack.depth, scale: 64,
                                 to: dir.appendingPathComponent("depth.raw"))
                if let working = stack.working {
                    try writeUnit16(working.pixels,
                                    to: dir.appendingPathComponent("working.raw"))
                }
                if let sharpness = stack.sharpness {
                    var flat = [Float]()
                    flat.reserveCapacity(sharpness.planes.count
                                         * (sharpness.planes.first?.count ?? 0))
                    for plane in sharpness.planes { flat.append(contentsOf: plane) }
                    let scale = max(flat.max() ?? 0, 1e-9)
                    try writeFixed16(flat, scale: 65535 / scale,
                                     to: dir.appendingPathComponent("sharpness.raw"))
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
        try JSONEncoder().encode(manifest)
            .write(to: temp.appendingPathComponent("manifest.json"))

        // Atomic swap: the existing project is only replaced by a fully
        // staged new one (the old delete-then-move destroyed the previous
        // save if the move failed).
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    private static func stackDirectoryName(_ index: Int) -> String {
        String(format: "stack_%03d", index)
    }

    // MARK: - Read

    static func read(from url: URL) throws -> Project {
        let manifestData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
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
                try readStack(stack, blobs: url.appendingPathComponent(stackDirectoryName(index)))
            }
            return Project(stacks: stacks, selectedIndex: manifest.selectedIndex,
                           bookmarks: manifest.bookmarks)
        case 2:
            let old = try JSONDecoder().decode(ManifestV2.self, from: manifestData)
            let adapted = StackManifest(
                name: URL(fileURLWithPath: old.framePaths.first ?? "Stack")
                    .deletingLastPathComponent().lastPathComponent,
                enabled: true,
                framePaths: old.framePaths, includedPaths: old.includedPaths,
                transforms: old.transforms, hasResult: true,
                resultWidth: old.resultWidth, resultHeight: old.resultHeight,
                hasWorking: old.hasWorking, sourceIndex: old.sourceIndex,
                gains: old.gains, slabPaths: old.slabPaths,
                slabFrameGains: old.slabFrameGains,
                sharpnessFactor: old.sharpnessFactor,
                sharpnessFullWidth: old.sharpnessFullWidth,
                sharpnessFullHeight: old.sharpnessFullHeight,
                sharpnessFrameCount: old.sharpnessFrameCount,
                sharpnessScale: old.sharpnessScale)
            return Project(stacks: [try readStack(adapted, blobs: url)],
                           selectedIndex: 0, bookmarks: old.bookmarks)
        default:
            throw NSError(domain: "Hyperfocal", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported session version \(probe.version)"])
        }
    }

    private static func readStack(_ manifest: StackManifest, blobs dir: URL) throws -> StackPayload {
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
            gains: manifest.gains,
            slabPaths: manifest.slabPaths,
            slabFrameGains: manifest.slabFrameGains,
            fusedSettings: manifest.fusedSettings,
            tone: manifest.tone)
        guard manifest.hasResult else { return payload }

        let w = manifest.resultWidth, h = manifest.resultHeight
        let resultPixels = try readUnit16(from: dir.appendingPathComponent("result.raw"),
                                          expected: w * h * 4)
        payload.result = ImageBuffer(width: w, height: h, pixels: resultPixels)
        payload.depth = try readFixed16(from: dir.appendingPathComponent("depth.raw"),
                                        scale: 64, expected: w * h)
        if manifest.hasWorking {
            let pixels = try readUnit16(from: dir.appendingPathComponent("working.raw"),
                                        expected: w * h * 4)
            payload.working = ImageBuffer(width: w, height: h, pixels: pixels)
        }
        if let factor = manifest.sharpnessFactor,
           let fullW = manifest.sharpnessFullWidth,
           let fullH = manifest.sharpnessFullHeight,
           let count = manifest.sharpnessFrameCount, count > 0 {
            let planeSize = ((fullW + factor - 1) / factor) * ((fullH + factor - 1) / factor)
            let scale = manifest.sharpnessScale ?? 1
            let flat = try readFixed16(from: dir.appendingPathComponent("sharpness.raw"),
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

    /// Unit-range floats (pixels) as UInt16.
    private static func writeUnit16(_ values: [Float], to url: URL) throws {
        try writeFixed16(values, scale: 65535, to: url)
    }

    private static func readUnit16(from url: URL, expected: Int) throws -> [Float] {
        try readFixed16(from: url, scale: 65535, expected: expected)
    }

    /// Fixed-point 16-bit encoding: stored = round(value * scale).
    private static func writeFixed16(_ values: [Float], scale: Float, to url: URL) throws {
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
        try samples.withUnsafeBytes { Data($0) }.write(to: url)
    }

    private static func readFixed16(from url: URL, scale: Float, expected: Int) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == expected * 2 else {
            throw NSError(domain: "Hyperfocal", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent): expected \(expected * 2) bytes, found \(data.count)"])
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
}
