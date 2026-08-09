import Foundation

/// Errors from the raw → DNG transcode fallback (see `RawConverter`).
///
/// Always compiled — even on Apple builds where the converter itself is absent —
/// so `AppModel` and the CLI can `catch` it uniformly and route the
/// missing-converter case to a guided-install prompt.
public enum RawConverterError: Error, CustomStringConvertible, LocalizedError {
    /// The Adobe DNG Converter is not installed. `file` is the raw file that
    /// needed it (display name, not a path) and `downloadURL` points at Adobe's
    /// download page so the caller can guide the user there.
    ///
    /// The file travels with the error because the message names it. An earlier
    /// wording blamed "this camera's raw files", which is wrong twice over: the
    /// same camera can be set to emit raws LibRaw reads perfectly, so the fault
    /// is the encoding of this particular file, and a stack can mix files that
    /// do and don't need the converter.
    case converterMissing(file: String, downloadURL: String)
    /// The converter was found and launched but produced no usable DNG.
    case conversionFailed(String)

    /// Keeps ArgumentParser (and any `\(error)`) rendering the clean message.
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .converterMissing(let file, let url):
            return String(format: localizedString(
                "%1$@ requires the free Adobe DNG Converter to decode. Download it from %2$@",
                comment: "Shown when an undecodable raw is opened without the Adobe DNG Converter; %1$@ is the file name, %2$@ the download URL"),
                file, url)
        case .conversionFailed(let detail):
            return String(format: localizedString(
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
/// DNG. Results are cached keyed by path+mtime+size, so the one-time convert is
/// shared across the full decode, the registration gray decode, and the
/// prefetcher.
///
/// The cache is **scoped to the process**, not kept: it exists so one stack's
/// frames can be decoded repeatedly within a run, and it is emptied on the way
/// out (see `purgeCache`). It used to live in `%LOCALAPPDATA%` and grow without
/// limit — 10 GB after a few sessions, keyed by *path*, so re-importing the same
/// frames from a copy silently stored them twice, with no UI anywhere that
/// admitted the directory existed.
///
/// Windows only for now; the converter-location and launch seams are the parts a
/// Linux/Wine path would later plug into.
public final class RawConverter {
    public static let shared = RawConverter()

    /// Invoked (once per source) just before a conversion begins, so the UI /
    /// CLI can surface progress. Set by `AppModel` and the CLI.
    public static var progressHandler: (@Sendable (String) -> Void)?

    private init() {}

    // MARK: - Cache lifetime

    /// Names the converter's scratch directories, so the sweep can recognize
    /// them (`runConversion` makes one per invocation).
    static let scratchPrefix = "hf-dngconv-"

    /// Deletes every transcode in the cache — this process's and any left by an
    /// earlier one.
    public static func purgeCache() {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheDirectory())
        // The converter's scratch directories are normally removed by the
        // `defer` that made them; a run that is killed between the two leaks
        // one, and nothing else would ever collect it. Two were sitting in
        // temp from a single afternoon's use when this was written.
        // `contentsOfDirectory(atPath:)`, not the URL form: the URL form asks
        // for resource values on every entry and gives up on the whole listing
        // if any one of them can't be read — which, in a real temp directory
        // full of other processes' locked files, it can't. Measured: the URL
        // form returned nothing at all here, so the sweep silently never ran.
        let temp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? []
        where name.hasPrefix(scratchPrefix) {
            try? fm.removeItem(at: temp.appendingPathComponent(name, isDirectory: true))
        }
        // The cache lived under %LOCALAPPDATA% before it was session-scoped,
        // where nothing ever deleted it: an existing install is sitting on
        // however many gigabytes its shoots added up to, and no code looks
        // there any more, so this is the only thing that will ever collect it.
        // Cheap to keep — after the first run it's a stat on a missing path.
        if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty {
            try? fm.removeItem(at: URL(fileURLWithPath: local, isDirectory: true)
                .appendingPathComponent("Hyperfocal", isDirectory: true)
                .appendingPathComponent("DNGCache", isDirectory: true))
        }
    }

    /// Runs once, the first time a transcode is wanted: clears whatever an
    /// earlier run left behind, and arranges to clear ours on the way out.
    ///
    /// Both halves are needed, because neither covers the other's case.
    /// `atexit` runs on a normal quit but not on a crash, a kill, or a power
    /// cut — and Windows offers no unprivileged way to say "delete this at
    /// reboot": `MOVEFILE_DELAY_UNTIL_REBOOT` writes the pending-rename list
    /// under HKLM, so it needs administrator rights, and it can only schedule
    /// files that already exist. `%TEMP%` is not emptied at boot either (
    /// Storage Sense prunes it by age, if it is switched on at all). So the
    /// startup sweep is what actually guarantees the residue is bounded: at
    /// worst it survives until the next launch.
    ///
    /// Deliberately at first *use* rather than at launch — a session that
    /// never opens a raw needing transcode shouldn't touch the disk at all.
    private static let cacheLifetime: Void = {
        purgeCache()
        atexit { RawConverter.purgeCache() }
    }()

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

    // MARK: - Whole-stack batching

    /// The frame list the next conversion belongs to, if a caller has named
    /// one (`ImageFile.expectStack`). Guarded by `batchLock`, which is also
    /// what serializes the batch run itself.
    private let batchLock = NSLock()
    private var expected: [URL] = []

    /// Names the stack about to be decoded, so the first frame that turns out
    /// to need transcoding converts the whole list in ONE converter process.
    ///
    /// Launching the converter per frame is almost entirely launch cost: it
    /// initializes Camera Raw (and probes for WinML models it doesn't find)
    /// on every start. Measured on 45 MP NEFs, 24 files: 1.02 s/file as one
    /// process each, 0.17 s/file handed to a single process — 6x, and the
    /// batch already uses the cores, so splitting it across several processes
    /// only bought another 0.03 s/file and is not worth the complexity.
    ///
    /// Batching necessarily converts the whole named list once any frame in
    /// it needs converting, so a stack that mixes decodable and undecodable
    /// raws transcodes a few frames it didn't have to. That costs cache space
    /// and nothing else: `convertedDNG` is still only *consulted* for a frame
    /// LibRaw actually rejected, so which decoder handles a given frame is
    /// unchanged — and the conversion is Bayer-preserving (`-c -p0`, never
    /// `-l`), so a converted frame decodes as its native raw would anyway.
    public func expectStack(_ urls: [URL]) {
        batchLock.lock()
        expected = urls
        batchLock.unlock()
    }

    /// Converts every not-yet-cached file of the expected stack in one
    /// invocation. Returns without doing anything if `source` isn't part of a
    /// named stack — the caller then converts it alone.
    private func convertExpectedStack(containing source: URL, exe: String) {
        batchLock.lock()
        defer { batchLock.unlock() }
        // Re-read under the lock: a racing thread may have run this batch
        // already, in which case every path below is a cache hit and the
        // pending list comes back empty.
        let stack = expected
        guard stack.contains(where: { $0.standardizedFileURL == source.standardizedFileURL })
        else { return }

        var pending = [(source: URL, cache: URL)]()
        for url in stack {
            guard let cache = try? cacheURL(for: url), !isUsable(cache) else { continue }
            pending.append((url, cache))
        }
        guard pending.count > 1 else { return }  // nothing to amortize

        RawConverter.progressHandler?(localizedString(
            "Converting raw files via Adobe DNG Converter…",
            comment: "Progress shown while transcoding a stack of unsupported raw files to DNG in one batch (Windows raw fallback)"))

        // The converter writes "<stem>.dng" beside -d, so a chunk must not
        // contain two sources with the same stem (possible when a stack spans
        // folders). Chunk on first repeat and let the next chunk take it.
        var chunk = [(source: URL, cache: URL)]()
        var stems = Set<String>()
        func flush() {
            guard !chunk.isEmpty else { return }
            try? runConversion(exe: exe, sources: chunk)
            chunk.removeAll()
            stems.removeAll()
        }
        for item in pending {
            let stem = item.source.deletingPathExtension().lastPathComponent.lowercased()
            if !stems.insert(stem).inserted { flush(); stems.insert(stem) }
            chunk.append(item)
        }
        flush()
    }

    /// Returns a cached DNG for `url`, converting on demand. Throws
    /// `RawConverterError.converterMissing` when the converter isn't installed,
    /// `.conversionFailed` when it ran but produced nothing usable.
    public func convertedDNG(for url: URL) throws -> URL {
        _ = RawConverter.cacheLifetime   // sweep once, and arm the exit purge
        let cachePath = try cacheURL(for: url)
        if isUsable(cachePath) { return cachePath }

        let sourceLock = lock(for: cachePath.path)
        sourceLock.lock()
        defer { sourceLock.unlock() }
        // Another thread may have converted it while we waited on the lock.
        if isUsable(cachePath) { return cachePath }

        guard let exe = locateConverter() else {
            throw RawConverterError.converterMissing(file: url.lastPathComponent,
                                                     downloadURL: adobeDNGConverterDownloadURL)
        }

        // This frame is the first of its stack to need transcoding, so convert
        // the whole stack now rather than paying the converter's launch cost
        // once per frame (see expectStack). Falls through to the single-file
        // path when no stack was named, or when the batch didn't produce this
        // file for any reason.
        convertExpectedStack(containing: url, exe: exe)
        if isUsable(cachePath) { return cachePath }

        RawConverter.progressHandler?(String(format: localizedString(
            "Converting %@ via Adobe DNG Converter…",
            comment: "Progress shown while transcoding an unsupported raw file to DNG"),
            url.lastPathComponent))

        try runConversion(exe: exe, sources: [(url, cachePath)])
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
        let dir = RawConverter.cacheDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(url.standardizedFileURL.path)|\(mtime)|\(size)"
        let stem = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem)-\(fnv1a(identity)).dng")
    }

    /// The temp directory, not `%LOCALAPPDATA%`: these transcodes are scratch
    /// that happens to be expensive, and nothing about them is worth keeping
    /// past the run that made them. Putting scratch under LOCALAPPDATA is also
    /// what let the old cache go unnoticed at 10 GB — temp is where a user, a
    /// disk-cleanup tool, or Storage Sense will actually look.
    static func cacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
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

    /// A path spelled the way the *platform* spells it, for handing to a child
    /// process.
    ///
    /// `URL.path` is not that on Windows: it yields forward slashes
    /// (`C:/Users/…`). Adobe DNG Converter reads that as a POSIX path, discards
    /// the drive, and reports `Failed to convert '/Users/…'` — while still
    /// exiting 0 and writing nothing, so the only visible symptom is "the
    /// converter could not convert this file". Same file, same flags, spelled
    /// `C:\Users\…`, converts fine. `fileSystemRepresentation` is the native
    /// spelling; the `.path` fallback only runs on platforms without one.
    private func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map(String.init(cString:)) ?? url.path
        }
    }

    /// Converts one or more sources in a single converter process, moving each
    /// output to its own cache path. Sources must have distinct stems (the
    /// converter names outputs after them) — `convertExpectedStack` chunks to
    /// guarantee that.
    private func runConversion(exe: String, sources: [(source: URL, cache: URL)]) throws {
        guard let first = sources.first else { return }
        let fm = FileManager.default
        // Convert into a private temp dir, then move the outputs into the
        // cache — the converter always writes "<stem>.dng" next to `-d`.
        //
        // The name must be unique per invocation, not a hash of what is being
        // converted. It used to be the latter, which meant two processes
        // converting the same stack — a second app instance, or a CLI run
        // beside the app — picked the same scratch directory, and whichever
        // got there second deleted it out from under the first. The converter
        // answers a missing `-d` by writing nothing at all and still exiting
        // 0 (measured), so the loser saw "could not convert this file" with no
        // hint why. UUID costs nothing and the collision cannot happen.
        let tmp = fm.temporaryDirectory
            .appendingPathComponent(RawConverter.scratchPrefix + UUID().uuidString,
                                    isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // -c: lossless-compressed DNG · -p0: no preview · -d: output directory.
        // Deliberately NOT -l (linear): keep the Bayer mosaic so LibRaw demosaics
        // it exactly as it would a native raw.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["-c", "-p0", "-d", nativePath(tmp)]
            + sources.map { nativePath($0.source) }
        do {
            try proc.run()
        } catch {
            throw RawConverterError.conversionFailed("\(first.source.lastPathComponent): \(error)")
        }
        proc.waitUntilExit()

        // Move what landed; a batch is best-effort per file, and anything the
        // converter skipped stays a cache miss for the single-file path to
        // retry and report on. Only a lone source raises here, so the
        // one-file caller keeps its exact previous behavior.
        var moved = 0
        for item in sources {
            let produced = tmp.appendingPathComponent(
                item.source.deletingPathExtension().lastPathComponent + ".dng")
            guard isUsable(produced) else { continue }
            try? fm.removeItem(at: item.cache)
            try? fm.moveItem(at: produced, to: item.cache)
            moved += 1
        }
        if moved == 0 && sources.count == 1 {
            // The converter reports most errors silently (exit 0, no output).
            throw RawConverterError.conversionFailed(first.source.lastPathComponent)
        }
    }
}

#endif
