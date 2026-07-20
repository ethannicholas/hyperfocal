import Foundation
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
/// even uncompressed TIFF and JPEG win). Frames are stored as warped fp32
/// RGBA by default — bit-identical to re-warping (the warp kernel is
/// deterministic, so the stored plane IS what pass 2 would compute), which
/// the ≥ 90 dB CPU↔GPU parity gate leans on. When fp32 doesn't fit the temp
/// volume, the spill *degrades to fp16* instead of vanishing: quantizing the
/// render inputs to ~75–80 dB is far better than re-decoding + re-warping
/// the whole stack, and machines where the gates run always fit fp32 (synth
/// stacks are tiny), so the parity bar is unaffected.
///
/// The backing file is unlinked immediately after creation — it lives only as
/// this object's file descriptor, so the space is reclaimed on deinit or
/// process death (even a crash can't leak a multi-GB temp file). Slots are
/// 16 KiB-aligned and the fd is F_NOCACHE: written once, read once, the
/// traffic shouldn't churn the unified buffer cache.
public final class FrameSpill {
    #if os(Windows)
    private let handle: HANDLE
    #else
    private let fd: Int32
    #endif
    private let frameBytes: Int   // fp32 payload size per frame (callers' unit)
    private let slotBytes: Int    // on-disk slot (halved when fp16)
    private let halfPrecision: Bool
    private var scratch: [UInt16] = []
    private let scratchLock = NSLock()

    /// Free space the spill must leave untouched on the temp volume.
    private static let margin: Int64 = 2 << 30

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
    /// silently fusing slower.
    public static func shortfall(frameBytes: Int,
                                 frameCount: Int) -> (needed: Int64, available: Int64)? {
        let slotBytes = (frameBytes + 0x3FFF) & ~0x3FFF
        let needed = Int64(slotBytes) * Int64(frameCount) + margin
        #if canImport(Darwin)
        guard let capacity = (try? FileManager.default.temporaryDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        #elseif os(Windows)
        // Bytes available to this caller (quota-aware), same figure the spill
        // has to fit inside.
        var free = ULARGE_INTEGER()
        let ok = FileManager.default.temporaryDirectory.path.withCString(encodedAs: UTF16.self) {
            GetDiskFreeSpaceExW($0, &free, nil, nil)
        }
        guard ok else { return nil }
        let capacity = Int64(free.QuadPart)
        #else
        // Linux has no "important usage" capacity; statvfs on the temp volume
        // reports the blocks available to an unprivileged writer, which is the
        // figure the spill has to fit inside.
        var vfs = Glibc.statvfs()
        guard statvfs(FileManager.default.temporaryDirectory.path, &vfs) == 0 else {
            return nil
        }
        let capacity = Int64(vfs.f_bavail) * Int64(vfs.f_frsize)
        #endif
        guard capacity < needed else { return nil }
        return (needed, capacity)
    }

    /// Returns nil (logging why) when the temp volume can't hold even the
    /// fp16 spill with headroom to spare, or the file can't be created —
    /// callers fall back to re-decoding. When fp32 doesn't fit but fp16
    /// does, the spill runs at half precision (logged).
    init?(frameBytes: Int, frameCount: Int, log: ((String) -> Void)? = nil) {
        self.frameBytes = frameBytes
        if FrameSpill.shortfall(frameBytes: frameBytes, frameCount: frameCount) == nil {
            halfPrecision = false
            slotBytes = (frameBytes + 0x3FFF) & ~0x3FFF
        } else if FrameSpill.shortfall(frameBytes: frameBytes / 2,
                                       frameCount: frameCount) == nil {
            halfPrecision = true
            slotBytes = (frameBytes / 2 + 0x3FFF) & ~0x3FFF
            log?("frame spill: fp32 won't fit the temp volume — caching at fp16")
        } else {
            let short = FrameSpill.shortfall(frameBytes: frameBytes / 2,
                                             frameCount: frameCount)!
            log?(String(format: "frame spill skipped: needs %.1f GB even at fp16, volume has %.1f GB free",
                        Double(short.needed) / Double(1 << 30),
                        Double(short.available) / Double(1 << 30)))
            return nil
        }
        let url = FileManager.default.temporaryDirectory
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

    // Public write/read speak fp32 (`frameBytes` of it) regardless of the
    // on-disk precision; fp16 conversion happens through a reused scratch
    // buffer (locked — the GPU paths may spill from a worker thread).
    func write(frame: Int, from ptr: UnsafeRawPointer) throws {
        guard halfPrecision else {
            return try writeRaw(frame: frame, from: ptr, byteCount: frameBytes)
        }
        let count = frameBytes / 4
        let src = ptr.assumingMemoryBound(to: Float.self)
        scratchLock.lock()
        defer { scratchLock.unlock() }
        if scratch.count < count { scratch = [UInt16](repeating: 0, count: count) }
        try scratch.withUnsafeMutableBufferPointer { sp in
            for i in 0..<count {
                // Clamp: Float16 traps above 65504; pixels live in [0,1] but
                // decode excursions must not crash the spill.
                sp[i] = Float16(min(max(src[i], -65504), 65504)).bitPattern
            }
            try writeRaw(frame: frame, from: UnsafeRawPointer(sp.baseAddress!),
                         byteCount: frameBytes / 2)
        }
    }

    func read(frame: Int, into ptr: UnsafeMutableRawPointer) throws {
        guard halfPrecision else {
            return try readRaw(frame: frame, into: ptr, byteCount: frameBytes)
        }
        let count = frameBytes / 4
        let dst = ptr.assumingMemoryBound(to: Float.self)
        scratchLock.lock()
        defer { scratchLock.unlock() }
        if scratch.count < count { scratch = [UInt16](repeating: 0, count: count) }
        try scratch.withUnsafeMutableBufferPointer { sp in
            try readRaw(frame: frame, into: sp.baseAddress!, byteCount: frameBytes / 2)
            for i in 0..<count {
                dst[i] = Float(Float16(bitPattern: sp[i]))
            }
        }
    }
}
