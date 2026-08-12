import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// Spills per-frame planes to a temp file during one fusion pass so a later
/// pass can stream them back instead of re-decoding the stack. DMap decodes
/// every frame twice (argmax pass, then render pass); streaming the warped
/// frame back from SSD replaces the render pass's decode + upload + warp and
/// measures faster for every input format (RAW by the widest margin, but
/// even uncompressed TIFF and JPEG win).
///
/// Frames are stored as warped RGBA **f16** — the pipeline's own storage
/// format (`ImageBuffer.pixels`), written and read verbatim. That makes the
/// round-trip bit-identical to re-warping (the warp kernel is deterministic,
/// so the stored plane IS what pass 2 would compute), which the ≥ 90 dB
/// CPU↔GPU parity gate leans on.
///
/// This class used to carry a *degrade-to-fp16* tier for temp volumes that
/// couldn't hold the fp32 spill (~75–80 dB, and the escape hatch for the
/// 45 MP case where a barely-fitting fp32 spill drove a volume to 97% full
/// and the fuse to 2124 s vs 469 s). Storage is f16 end to end now, so the
/// spill is already half what it was and the tier has nothing left to halve;
/// a spill that still doesn't fit is skipped, and the caller re-decodes.
///
/// The backing file is unlinked immediately after creation — it lives only as
/// this object's file descriptor, so the space is reclaimed on deinit or
/// process death (even a crash can't leak a multi-GB temp file). Slots are
/// 16 KiB-aligned and the fd is F_NOCACHE: written once, read once, the
/// traffic shouldn't churn the unified buffer cache.
/// A DMap fuse's pass-1 warped-frame spill, retained past the fuse so
/// follow-on consumers can stream the already-decoded, already-warped frames
/// instead of re-decoding the stack. Two kinds of consumer: the app's
/// background secondary generation (its RAW re-decode contends with retouch's
/// on-demand source loads on Apple's internally-parallel RAW engine — see
/// `FramePrefetcher.workers(for:)` — measured ≥4× slower end-to-end under
/// that load, while spill reads are plain SSD I/O, immune to it), and
/// on-demand aligned-frame views over the same result (`StackSource.warped`:
/// retouch brush sources, the input pane), which otherwise pay a full RAW
/// decode + warp per cache-missed frame switch. Dimensions ride along so a
/// consumer can verify the cache matches its canvas. The spill's disk space
/// (multi-GB, unlinked temp) is reclaimed when the last reference dies —
/// the app deliberately holds it for the *lifetime of the fused result* it
/// belongs to (released on re-fuse, stack switch, project close), because
/// the result is exactly as long as frame views of it can be requested.
/// Reads are positional (pread/OVERLAPPED) — concurrent readers are safe.
///
/// Occupancy is per-slot, not all-or-nothing: fusion writes every slot and
/// drains before reading, but a cache can also start EMPTY
/// (`lazyCache(width:height:frameCount:)`) and fill one frame at a time as
/// decodes flow through `StackSource.frame(at:)` — the resumed-session case,
/// where the fuse's spill didn't survive the process. Twenty cached frames
/// of a 200-frame stack are twenty SSD-fast switches; `frame(_:)` throws on
/// an unwritten slot (the file is sparse — reading one would silently return
/// zeros) and the caller falls back to decoding.
public struct WarpedFrameCache {
    let spill: FrameSpill
    public let width: Int
    public let height: Int
    public let frameCount: Int

    /// Streams frame `i` back as an ImageBuffer — the stored bytes ARE the
    /// buffer's storage format, so this is a straight read. Throws when the
    /// slot was never written (partial cache): that's a miss, not corruption.
    func frame(_ i: Int) throws -> ImageBuffer {
        guard spill.isPopulated(i) else {
            throw StackError.io("frame \(i) is not in the cache")
        }
        var buf = ImageBuffer(width: width, height: height)
        try buf.pixels.withUnsafeMutableBufferPointer { p in
            try spill.read(frame: i, into: p.baseAddress!)
        }
        return buf
    }

    /// Slots currently written. Fusion-produced caches are complete by
    /// construction; lazily-filled ones hold any subset.
    public var populatedCount: Int { spill.populatedCount }
    /// Whether every slot is written — the bar for consumers that stream the
    /// whole stack (the background secondary), as opposed to per-frame views,
    /// which work at any occupancy.
    public var isComplete: Bool { spill.populatedCount == frameCount }

    /// An empty cache that fills via `store(frame:buffer:)` as decodes flow
    /// through `StackSource` write-back. No full-size preflight: the backing
    /// file is sparse and every write re-checks disk headroom, so the cache
    /// sizes itself to the volume and simply stops growing when space runs
    /// short — it keeps serving whatever it already holds.
    public static func lazyCache(width: Int, height: Int, frameCount: Int,
                                 log: ((String) -> Void)? = nil) -> WarpedFrameCache? {
        guard width > 0, height > 0, frameCount > 0,
              let spill = FrameSpill(frameBytes: width * height * 8,
                                     frameCount: frameCount,
                                     preflight: false, log: log) else { return nil }
        return WarpedFrameCache(spill: spill, width: width, height: height,
                                frameCount: frameCount)
    }

    /// Write-back seam for `StackSource.frame(at:)`: queue `buffer` (pre-gain,
    /// canvas-sized) into slot `i`. Asynchronous, bounded, and best-effort —
    /// a frame that can't be written (queue busy, disk tight, wrong
    /// dimensions) just stays uncached.
    func store(frame i: Int, buffer: ImageBuffer) {
        guard (0..<frameCount).contains(i),
              buffer.width == width, buffer.height == height else { return }
        spill.storeAsync(frame: i, buffer: buffer)
    }

    /// Disk actually held by the retained spill (its unlinked temp file):
    /// written slots only — the file is sparse, so unwritten slots occupy
    /// nothing. Reclaimed the moment the last reference dies. A caller
    /// preflighting a NEW fuse's disk needs (which supersedes and releases
    /// this cache) should credit these bytes as available — see
    /// `FrameSpill.shortfall(frameBytes:frameCount:reclaimable:)`.
    public var diskBytes: Int64 {
        Int64(spill.slotBytes) * Int64(spill.populatedCount)
    }
}

public final class FrameSpill {
    #if os(Windows)
    private let handle: HANDLE
    #else
    private let fd: Int32
    #endif
    private let frameBytes: Int   // payload size per frame (f16 RGBA)
    let slotBytes: Int            // on-disk slot (frameBytes, 16 KiB-aligned)
    private let scratchLock = NSLock()

    // HYPERFOCAL_SPILL_DEBUG=1: staging vs raw-I/O time split, printed at
    // teardown — the measurement tap for spill performance work.
    private static let debugTiming =
        ProcessInfo.processInfo.environment["HYPERFOCAL_SPILL_DEBUG"] == "1"
    private var tConvert = 0.0, tIO = 0.0
    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// Free space the spill must leave untouched on the temp volume: 2 GB,
    /// or half the spill's own size for large spills. The flat 2 GB floor
    /// let a 7.3 GB spill "fit" a volume with 9.3 GB free (Fluorite 45 MP × 10
    /// on the dev VM, 2026-07-21) — driving the volume to 97% full, where
    /// write latency collapses: that fuse took 2124 s against 469 s for a
    /// half-size spill. Proportional headroom demotes exactly those
    /// barely-fits cases.
    private static func margin(for spillBytes: Int64) -> Int64 {
        max(2 << 30, spillBytes / 2)
    }

    /// Resolves the HYPERFOCAL_DMAP_SPILL override against the caller's
    /// setting (the app's Settings toggle / CLI flag): "1" forces the spill
    /// on, "0" forces it off, anything else defers to `enabled`.
    public static func wanted(_ enabled: Bool) -> Bool {
        switch ProcessInfo.processInfo.environment["HYPERFOCAL_DMAP_SPILL"] {
        case "1": return true
        case "0": return false
        default: return enabled
        }
    }

    /// How a full spill compares to the temp volume's free capacity — nil
    /// when it fits (with margin) or capacity can't be determined. Public so
    /// the app can warn *before* fusing that the cache won't fit, instead of
    /// silently fusing slower. `reclaimable` is disk the caller knows it is
    /// about to release before this spill grows (the previous fuse's retained
    /// `WarpedFrameCache`, superseded by the new fuse) — credited to the
    /// volume's capacity so a re-fuse isn't warned about space its own stale
    /// cache is holding.
    public static func shortfall(frameBytes: Int, frameCount: Int,
                                 reclaimable: Int64 = 0)
        -> (needed: Int64, available: Int64)? {
        let slotBytes = (frameBytes + 0x3FFF) & ~0x3FFF
        let spillBytes = Int64(slotBytes) * Int64(frameCount)
        let needed = spillBytes + margin(for: spillBytes)
        guard let capacity = freeCapacity() else { return nil }
        let effective = capacity + reclaimable
        guard effective < needed else { return nil }
        return (needed, effective)
    }

    /// Free bytes on the spill volume as seen by an unprivileged writer —
    /// nil when the figure can't be determined.
    static func freeCapacity() -> Int64? {
        #if canImport(Darwin)
        guard let capacity = (try? FrameSpill.spillDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return capacity
        #elseif os(Windows)
        // Bytes available to this caller (quota-aware), same figure the spill
        // has to fit inside.
        var free = ULARGE_INTEGER()
        let ok = FrameSpill.spillDirectory.path.withCString(encodedAs: UTF16.self) {
            GetDiskFreeSpaceExW($0, &free, nil, nil)
        }
        guard ok else { return nil }
        return Int64(free.QuadPart)
        #else
        // Linux has no "important usage" capacity; statvfs on the spill volume
        // reports the blocks available to an unprivileged writer, which is the
        // figure the spill has to fit inside.
        var vfs = Glibc.statvfs()
        guard statvfs(FrameSpill.spillDirectory.path, &vfs) == 0 else {
            return nil
        }
        return Int64(vfs.f_bavail) * Int64(vfs.f_frsize)
        #endif
    }

    /// Where the spill file lives (also the volume the preflight measures).
    /// The temporary directory — except on Linux, where /tmp is
    /// conventionally tmpfs (RAM + swap): spilling gigabytes there would
    /// consume exactly the memory the spill exists to avoid, while the
    /// preflight happily approves it against tmpfs's "free space". The user
    /// cache directory is disk-backed by convention, and the unlink-after-
    /// create pattern keeps it invisible there just the same.
    static var spillDirectory: URL {
        #if os(Linux)
        if let cache = FileManager.default.urls(for: .cachesDirectory,
                                                in: .userDomainMask).first {
            let dir = cache.appendingPathComponent("hyperfocal", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        return FileManager.default.temporaryDirectory
    }

    /// Returns nil (logging why) when the spill volume can't hold the spill
    /// with headroom to spare, or the file can't be created — callers fall
    /// back to re-decoding. `preflight: false` skips the full-size capacity
    /// check for lazily-filled caches: the file is sparse and `storeAsync`
    /// re-checks headroom per write instead, so a partial cache can exist on
    /// a volume that could never hold the whole stack.
    init?(frameBytes: Int, frameCount: Int, preflight: Bool = true,
          log: ((String) -> Void)? = nil) {
        self.frameBytes = frameBytes
        self.populatedFlags = [Bool](repeating: false, count: frameCount)
        writeQueue.setSpecific(key: queueKey, value: true)
        if preflight,
           let short = FrameSpill.shortfall(frameBytes: frameBytes, frameCount: frameCount) {
            log?(String(format: "frame spill skipped: needs %.1f GB, volume has %.1f GB free",
                        Double(short.needed) / Double(1 << 30),
                        Double(short.available) / Double(1 << 30)))
            return nil
        }
        slotBytes = (frameBytes + 0x3FFF) & ~0x3FFF
        let url = FrameSpill.spillDirectory
            .appendingPathComponent("hyperfocal-spill-\(UUID().uuidString).bin")
        #if os(Windows)
        // DELETE_ON_CLOSE is the Win32 spelling of the unlink-after-create
        // pattern: the file exists only as this handle, and the kernel
        // reclaims it on close or process death. TEMPORARY hints the cache
        // that the data never needs to survive.
        let h = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, GENERIC_READ | DWORD(GENERIC_WRITE), 0, nil,
                        DWORD(CREATE_NEW),
                        DWORD(FILE_ATTRIBUTE_TEMPORARY) | DWORD(FILE_FLAG_DELETE_ON_CLOSE),
                        nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else {
            log?("frame spill unavailable: CreateFileW failed (error \(GetLastError()))")
            return nil
        }
        handle = h
        #else
        fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            log?("frame spill unavailable: open failed (errno \(errno))")
            return nil
        }
        unlink(url.path)
        #if canImport(Darwin)
        _ = fcntl(fd, F_NOCACHE, 1)
        #else
        // Linux has no F_NOCACHE; drop this write-once/read-once file from the
        // page cache so its multi-GB traffic doesn't evict the working set.
        _ = posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)
        #endif
        #endif
    }

    deinit {
        // Never close the handle under an in-flight write — but an async
        // write's block can itself hold the LAST reference (a lazily-filled
        // cache released with a store queued; a cancelled fuse unwinding past
        // its spill), which lands this deinit ON the write queue, where a
        // sync drain is a dispatch deadlock trap. In that position the drain
        // is also unnecessary: the finishing block is the queue's tail —
        // any other queued write would hold its own reference and this
        // deinit wouldn't be running.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            writeQueue.sync {}
        }
        if FrameSpill.debugTiming {
            FileHandle.standardError.write(Data(String(
                format: "spill timing: staging %.2fs, io %.2fs\n",
                tConvert, tIO).utf8))
        }
        #if os(Windows)
        CloseHandle(handle)
        #else
        close(fd)
        #endif
    }

    #if os(Windows)
    // Positional I/O on Windows: a synchronous handle plus an OVERLAPPED
    // offset is the pwrite/pread equivalent — no shared file pointer, so
    // concurrent slot writes stay safe.
    private func overlapped(at offset: UInt64) -> OVERLAPPED {
        var ov = OVERLAPPED()
        ov.Offset = DWORD(truncatingIfNeeded: offset)
        ov.OffsetHigh = DWORD(truncatingIfNeeded: offset >> 32)
        return ov
    }

    private func writeRaw(frame: Int, from ptr: UnsafeRawPointer, byteCount: Int) throws {
        var done = 0
        while done < byteCount {
            var ov = overlapped(at: UInt64(frame * slotBytes + done))
            var n: DWORD = 0
            guard WriteFile(handle, ptr + done, DWORD(byteCount - done), &n, &ov),
                  n > 0 else {
                throw StackError.io("spill write failed (error \(GetLastError()))")
            }
            done += Int(n)
        }
    }

    private func readRaw(frame: Int, into ptr: UnsafeMutableRawPointer, byteCount: Int) throws {
        var done = 0
        while done < byteCount {
            var ov = overlapped(at: UInt64(frame * slotBytes + done))
            var n: DWORD = 0
            guard ReadFile(handle, ptr + done, DWORD(byteCount - done), &n, &ov) else {
                throw StackError.io("spill read failed (error \(GetLastError()))")
            }
            if n == 0 {
                throw StackError.io("spill read hit EOF at frame \(frame)")
            }
            done += Int(n)
        }
    }
    #else
    private func writeRaw(frame: Int, from ptr: UnsafeRawPointer, byteCount: Int) throws {
        var done = 0
        while done < byteCount {
            let n = pwrite(fd, ptr + done, byteCount - done,
                           off_t(frame * slotBytes + done))
            if n < 0 {
                if errno == EINTR { continue }
                throw StackError.io("spill write failed (errno \(errno))")
            }
            done += n
        }
    }

    private func readRaw(frame: Int, into ptr: UnsafeMutableRawPointer, byteCount: Int) throws {
        var done = 0
        while done < byteCount {
            let n = pread(fd, ptr + done, byteCount - done,
                          off_t(frame * slotBytes + done))
            if n < 0 {
                if errno == EINTR { continue }
                throw StackError.io("spill read failed (errno \(errno))")
            }
            if n == 0 {
                throw StackError.io("spill read hit EOF at frame \(frame)")
            }
            done += n
        }
    }
    #endif

    // MARK: - Slot occupancy
    // Which slots hold a written frame (scratchLock-guarded). Fusion writes
    // every slot and drains before reading; lazily-filled caches hold any
    // subset, and readers must treat an unwritten slot as a miss — the file
    // is sparse, so reading one would silently return zeros, not fail.
    private var populatedFlags: [Bool]
    private var _populatedCount = 0

    var populatedCount: Int {
        scratchLock.lock(); defer { scratchLock.unlock() }
        return _populatedCount
    }

    func isPopulated(_ frame: Int) -> Bool {
        scratchLock.lock(); defer { scratchLock.unlock() }
        return populatedFlags.indices.contains(frame) && populatedFlags[frame]
    }

    private func markPopulated(_ frame: Int) {
        scratchLock.lock(); defer { scratchLock.unlock() }
        guard populatedFlags.indices.contains(frame), !populatedFlags[frame] else { return }
        populatedFlags[frame] = true
        _populatedCount += 1
    }

    // Write/read move the caller's f16 RGBA payload verbatim.
    func write(frame: Int, from ptr: UnsafeRawPointer) throws {
        let t0 = FrameSpill.now()
        try writeRaw(frame: frame, from: ptr, byteCount: frameBytes)
        tIO += FrameSpill.now() - t0
        markPopulated(frame)
    }

    // MARK: - Overlapped writes
    // The spill's cost is raw I/O (measured: staging 2.7 s vs I/O 32 s for an
    // 82-frame stack on the reference VM), and pass 1's writes were serial
    // with compute. `writeAsync` stages the payload synchronously (a copy —
    // tens of ms) and performs the positional write on a background queue; up
    // to two frames stage at once, then the caller blocks. Errors surface at
    // `drainWrites` — callers must call it before the first read.
    private let writeQueue = DispatchQueue(label: "hyperfocal.spill.write")
    /// Marks THIS instance's writeQueue so deinit can tell it is running on
    /// it (see deinit). Per-instance, so one spill dying inside another
    /// spill's block can't be misread.
    private let queueKey = DispatchSpecificKey<Bool>()
    private let stagingFree = DispatchSemaphore(value: 2)
    private var asyncError: Error?
    // Staging buffers recycle through this pool (bounded by the semaphore's
    // in-flight cap of 2). Allocating per frame was measured at 36 s of the
    // Fluorite 45 MP run's critical path: a fresh zeroed 726 MB array per
    // frame is 7 GB of page-zeroing churn on an 8 GB machine.
    private var stagingPool: [[UInt8]] = []

    func writeAsync(frame: Int, from ptr: UnsafeRawPointer) {
        stagingFree.wait()
        let t0 = FrameSpill.now()
        let payloadBytes = frameBytes
        scratchLock.lock()
        var staged = stagingPool.popLast() ?? []
        scratchLock.unlock()
        if staged.count < payloadBytes {
            staged = [UInt8](repeating: 0, count: payloadBytes)
        }
        staged.withUnsafeMutableBytes { sb in
            sb.baseAddress!.copyMemory(from: ptr, byteCount: frameBytes)
        }
        scratchLock.lock()
        tConvert += FrameSpill.now() - t0
        scratchLock.unlock()
        // Immutable binding for the closure: `var staged` captured in
        // concurrently-executing code is a Swift 6 error. Same storage, no
        // copy — the pool round-trip keeps it uniquely referenced.
        let payload = staged
        writeQueue.async { [self] in
            let t1 = FrameSpill.now()
            do {
                try payload.withUnsafeBytes {
                    try writeRaw(frame: frame, from: $0.baseAddress!,
                                 byteCount: payloadBytes)
                }
                markPopulated(frame)
            } catch {
                scratchLock.lock()
                if asyncError == nil { asyncError = error }
                scratchLock.unlock()
            }
            scratchLock.lock()
            tIO += FrameSpill.now() - t1
            stagingPool.append(payload)
            scratchLock.unlock()
            stagingFree.signal()
        }
    }

    /// Blocks until every queued write has landed; throws the first write
    /// error (after which the file contents are unreliable — callers degrade
    /// to re-decoding).
    func drainWrites() throws {
        writeQueue.sync {}
        scratchLock.lock()
        defer { scratchLock.unlock() }
        if let e = asyncError { throw e }
    }

    // MARK: - Lazy write-back (cache-style spills)

    // Stores queued but not yet written (scratchLock-guarded). Capped at 2:
    // rapid frame browsing outruns the SSD, and each queued store pins one
    // full-resolution buffer — an unbounded queue would be a memory spike.
    private var pendingStores = 0

    /// Best-effort slot write for lazily-filled caches: non-throwing, bounded,
    /// and disk-aware — a slot that can't be written (queue busy, volume
    /// tight, I/O error) just stays uncached and decodes next time. The
    /// buffer is captured as-is: copy-on-write keeps its pixels alive for the
    /// queued write, and a caller mutating its own copy afterward (applying
    /// gains) copies rather than racing the I/O.
    func storeAsync(frame: Int, buffer: ImageBuffer) {
        scratchLock.lock()
        guard pendingStores < 2,
              populatedFlags.indices.contains(frame), !populatedFlags[frame] else {
            scratchLock.unlock()
            return
        }
        pendingStores += 1
        scratchLock.unlock()
        writeQueue.async { [self] in
            defer {
                scratchLock.lock()
                pendingStores -= 1
                scratchLock.unlock()
            }
            // Grow only while the volume keeps the same headroom the
            // preflighted spill insists on — sized to what the cache actually
            // holds, so it stops growing (not serving) when disk runs short.
            let grown = Int64(slotBytes) * Int64(populatedCount + 1)
            guard let free = FrameSpill.freeCapacity(),
                  free - Int64(slotBytes) >= FrameSpill.margin(for: grown) else { return }
            let t0 = FrameSpill.now()
            do {
                try buffer.pixels.withUnsafeBufferPointer {
                    try writeRaw(frame: frame, from: $0.baseAddress!,
                                 byteCount: frameBytes)
                }
                markPopulated(frame)
            } catch {}
            scratchLock.lock()
            tIO += FrameSpill.now() - t0
            scratchLock.unlock()
        }
    }

    func read(frame: Int, into ptr: UnsafeMutableRawPointer) throws {
        let t0 = FrameSpill.now()
        try readRaw(frame: frame, into: ptr, byteCount: frameBytes)
        tIO += FrameSpill.now() - t0
    }
}
