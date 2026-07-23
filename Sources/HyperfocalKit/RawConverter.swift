import Foundation

/// Errors from the raw → DNG transcode fallback (see `RawConverter`).
///
/// Always compiled — even on Apple builds where the converter itself is absent —
/// so `AppModel` and the CLI can `catch` it uniformly and route the
/// missing-converter case to a guided-install prompt.
public enum RawConverterError: Error, CustomStringConvertible, LocalizedError {
    /// The Adobe DNG Converter is not installed. `downloadURL` points at Adobe's
    /// download page so the caller can guide the user there.
    case converterMissing(downloadURL: String)
    /// The converter was found and launched but produced no usable DNG.
    case conversionFailed(String)

    /// Keeps ArgumentParser (and any `\(error)`) rendering the clean message.
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .converterMissing(let url):
            return String(format: NSLocalizedString(
                "This camera's raw files need the free Adobe DNG Converter, which isn't installed. Download it from %@",
                comment: "Shown when an undecodable raw is opened without the Adobe DNG Converter"), url)
        case .conversionFailed(let detail):
            return String(format: NSLocalizedString(
                "Adobe DNG Converter could not convert this file: %@",
                comment: "Shown when the Adobe DNG Converter runs but produces no output"), detail)
        }
    }
}

/// Adobe's free DNG Converter download page.
public let adobeDNGConverterDownloadURL =
    "https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html"

#if !canImport(CoreGraphics)

/// Transcodes camera raw files that LibRaw cannot decode (Nikon High-Efficiency
/// NEFs, or cameras newer than the installed LibRaw) into losslessly-compressed
/// Bayer DNGs via the free **Adobe DNG Converter**, then lets LibRaw decode the
/// DNG. Results are cached persistently keyed by path+mtime+size, so the one-time
/// convert is shared across the full decode, the registration gray decode, and
/// the prefetcher.
///
/// Windows only for now; the converter-location and launch seams are the parts a
/// Linux/Wine path would later plug into.
public final class RawConverter {
    public static let shared = RawConverter()

    /// Invoked (once per source) just before a conversion begins, so the UI /
    /// CLI can surface progress. Set by `AppModel` and the CLI.
    public static var progressHandler: (@Sendable (String) -> Void)?

    private init() {}

    // Serializes conversions of the *same* source so concurrent decoders (full
    // RGBA + registration gray + prefetch) convert once. Different sources still
    // run concurrently.
    private let mapLock = NSLock()
    private var perSourceLocks: [String: NSLock] = [:]

    private func lock(for key: String) -> NSLock {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let existing = perSourceLocks[key] { return existing }
        let created = NSLock()
        perSourceLocks[key] = created
        return created
    }

    /// Returns a cached DNG for `url`, converting on demand. Throws
    /// `RawConverterError.converterMissing` when the converter isn't installed,
    /// `.conversionFailed` when it ran but produced nothing usable.
    public func convertedDNG(for url: URL) throws -> URL {
        let cachePath = try cacheURL(for: url)
        if isUsable(cachePath) { return cachePath }

        let sourceLock = lock(for: cachePath.path)
        sourceLock.lock()
        defer { sourceLock.unlock() }
        // Another thread may have converted it while we waited on the lock.
        if isUsable(cachePath) { return cachePath }

        guard let exe = locateConverter() else {
            throw RawConverterError.converterMissing(downloadURL: adobeDNGConverterDownloadURL)
        }

        RawConverter.progressHandler?(String(format: NSLocalizedString(
            "Converting %@ via Adobe DNG Converter…",
            comment: "Progress shown while transcoding an unsupported raw file to DNG"),
            url.lastPathComponent))

        try runConversion(exe: exe, source: url, into: cachePath)
        guard isUsable(cachePath) else {
            throw RawConverterError.conversionFailed(url.lastPathComponent)
        }
        return cachePath
    }

    // MARK: - Locating the converter

    /// The converter executable, or nil if not found. `HYPERFOCAL_DNG_CONVERTER`
    /// overrides the standard install locations (also the test seam).
    public func locateConverter() -> String? {
        let fm = FileManager.default
        // fileExists (not isExecutableFile): the POSIX X_OK check behind
        // isExecutableFile isn't meaningful on Windows, where these are known
        // .exe paths anyway.
        if let override = ProcessInfo.processInfo.environment["HYPERFOCAL_DNG_CONVERTER"],
           !override.isEmpty {
            return fm.fileExists(atPath: override) ? override : nil
        }
        let candidates = [
            #"C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe"#,
            #"C:\Program Files (x86)\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe"#,
        ]
        return candidates.first { fm.fileExists(atPath: $0) }
    }

    // MARK: - Cache path

    private func cacheURL(for url: URL) throws -> URL {
        let dir = cacheDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(url.standardizedFileURL.path)|\(mtime)|\(size)"
        let stem = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem)-\(fnv1a(identity)).dng")
    }

    private func cacheDirectory() -> URL {
        if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty {
            return URL(fileURLWithPath: local, isDirectory: true)
                .appendingPathComponent("Hyperfocal", isDirectory: true)
                .appendingPathComponent("DNGCache", isDirectory: true)
        }
        // Fallback for non-Windows hosts of this code path.
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Hyperfocal", isDirectory: true)
            .appendingPathComponent("DNGCache", isDirectory: true)
    }

    private func isUsable(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        return size > 0
    }

    /// FNV-1a (64-bit) of the identity string, lowercase hex.
    private func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Running the converter

    private func runConversion(exe: String, source: URL, into cachePath: URL) throws {
        let fm = FileManager.default
        // Convert into a unique temp dir, then move the single output into the
        // cache — the converter always writes "<stem>.dng" next to `-d`, and a
        // private dir avoids collisions between concurrent conversions.
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("hf-dngconv-\(fnv1a(cachePath.path))", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // -c: lossless-compressed DNG · -p0: no preview · -d: output directory.
        // Deliberately NOT -l (linear): keep the Bayer mosaic so LibRaw demosaics
        // it exactly as it would a native raw.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["-c", "-p0", "-d", tmp.path, source.path]
        do {
            try proc.run()
        } catch {
            throw RawConverterError.conversionFailed("\(source.lastPathComponent): \(error)")
        }
        proc.waitUntilExit()

        let produced = tmp.appendingPathComponent(
            source.deletingPathExtension().lastPathComponent + ".dng")
        guard isUsable(produced) else {
            // The converter reports most errors silently (exit 0, no output).
            throw RawConverterError.conversionFailed(source.lastPathComponent)
        }
        // Move into place; replace any stale/partial cache entry.
        try? fm.removeItem(at: cachePath)
        try fm.moveItem(at: produced, to: cachePath)
    }
}

#endif
