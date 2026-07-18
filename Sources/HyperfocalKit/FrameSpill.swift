import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Spills per-frame planes to a temp file during one fusion pass so a later
/// pass can stream them back instead of re-decoding the stack. DMap decodes
/// every frame twice (argmax pass, then render pass); streaming the warped
/// frame back from SSD replaces the render pass's decode + upload + warp and
/// measures faster for every input format (RAW by the widest margin, but
/// even uncompressed TIFF and JPEG win). Frames are stored as warped fp32
/// RGBA — deliberately not fp16, which would halve the I/O but quantize the
/// render inputs to ~75–80 dB and break the ≥ 90 dB CPU↔GPU parity gate.
/// fp32 spill is bit-identical to re-warping: the warp kernel is
/// deterministic, so the stored plane IS what pass 2 would compute.
///
/// The backing file is unlinked immediately after creation — it lives only as
/// this object's file descriptor, so the space is reclaimed on deinit or
/// process death (even a crash can't leak a multi-GB temp file). Slots are
/// 16 KiB-aligned and the fd is F_NOCACHE: written once, read once, the
/// traffic shouldn't churn the unified buffer cache.
public final class FrameSpill {
    private let fd: Int32
    private let frameBytes: Int
    private let slotBytes: Int

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

    /// Returns nil (logging why) when the temp volume can't hold the spill
    /// with headroom to spare, or the file can't be created — callers fall
    /// back to re-decoding.
    init?(frameBytes: Int, frameCount: Int, log: ((String) -> Void)? = nil) {
        self.frameBytes = frameBytes
        self.slotBytes = (frameBytes + 0x3FFF) & ~0x3FFF
        if let short = FrameSpill.shortfall(frameBytes: frameBytes, frameCount: frameCount) {
            log?(String(format: "frame spill skipped: needs %.1f GB, volume has %.1f GB free",
                        Double(short.needed) / Double(1 << 30),
                        Double(short.available) / Double(1 << 30)))
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperfocal-spill-\(UUID().uuidString).bin")
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
    }

    deinit {
        close(fd)
    }

    func write(frame: Int, from ptr: UnsafeRawPointer) throws {
        var done = 0
        while done < frameBytes {
            let n = pwrite(fd, ptr + done, frameBytes - done,
                           off_t(frame * slotBytes + done))
            if n < 0 {
                if errno == EINTR { continue }
                throw StackError.io("spill write failed (errno \(errno))")
            }
            done += n
        }
    }

    func read(frame: Int, into ptr: UnsafeMutableRawPointer) throws {
        var done = 0
        while done < frameBytes {
            let n = pread(fd, ptr + done, frameBytes - done,
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
}
