import Foundation

/// Full-resolution decoded frames carried from the registration pass into the
/// fusion pass, so a stack is decoded once per fuse instead of twice.
///
/// The double decode is not a design choice anyone made; it is a discard.
/// `ImageFile.loadGray8CGImage` takes the cheap-looking route for most formats
/// (decode straight to 8-bit gray), but a RAW file has no cheap route to gray:
/// it calls `loadRAW`, producing exactly the RGBA f16 buffer fusion wants, and
/// then throws it away to keep 1/16th of it as luminance. Fusion then decodes
/// the same file again. On the 78 × 45 MP NEF reference stack that is ~9.5 s of
/// registration and ~6.9 s of fusion decode-wait out of ~20 s — against 0.05 s
/// of GPU compute (M5 Max, 2026-08-11). Decode *is* the wall clock; this class
/// deletes half of it.
///
/// **Reuse is exact, not approximate.** Registration's RAW path and fusion's
/// `ImageFile.load` both call `ImageFile.loadRAW(url:)`, which is deterministic
/// for a given file (as-shot settings, draft mode off — see its doc comment).
/// The cached buffer is therefore the same bytes the second decode would have
/// produced, which is why this needs no tolerance and no parity bar.
///
/// **Only populated where the decode was already paid for.** RAW on Apple is
/// the case where making the gray requires making the full buffer. Everywhere
/// else — non-RAW on Apple, and the whole CImaging path, which decodes gray
/// directly and never materializes RGBA — producing a buffer to cache would be
/// *extra* work, not saved work, so nothing is offered and this stays empty.
/// The rule is "never discard what we already made", never "make it early".
///
/// **Reads are destructive.** Taking a frame drops the cache's reference, so
/// peak memory falls as fusion consumes the stack instead of holding the whole
/// decode alive alongside fusion's own working set. A second pass over the same
/// frames (DMap's render pass) finds the cache empty and falls back — which is
/// correct and already fast, because that pass prefers `FrameSpill` anyway.
public final class DecodedFrameCache {
    private let lock = NSLock()
    private var frames: [URL: ImageBuffer] = [:]
    private var usedBytes: Int64 = 0
    private let budgetBytes: Int64
    private var offered = 0
    private var kept = 0

    public init(budgetBytes: Int64) {
        self.budgetBytes = max(0, budgetBytes)
    }

    /// Bytes worth of decoded frames it is safe to carry across the
    /// registration→fusion boundary. One eighth of physical memory, which is
    /// deliberately conservative: the tight moment is the *end* of registration,
    /// where the cache is at its fullest and fusion is starting to allocate its
    /// own working set on top (a 45 MP fuse peaks at 12–13 GB by itself). The
    /// cache drains from there, so the budget only has to survive that overlap.
    ///
    /// Sized in bytes rather than frames because frame size varies ~30× across
    /// the stacks we handle (a 2 MP JPEG to a 45 MP RAW is 16 MB to 360 MB), and
    /// a frame count tuned on one would be badly wrong on the other. Same
    /// instinct as `FramePrefetcher.defaultLookahead`, which sizes its window
    /// against physical memory for the same reason.
    ///
    /// On a 128 GB machine this is 16 GB — ~44 frames of 45 MP RAW, most of the
    /// reference stack. On 8 GB it is 1 GB, about 2 frames: a small machine gets
    /// a small benefit rather than a swap storm, and gets it without a special
    /// case.
    /// HYPERFOCAL_DECODE_REUSE overrides for ablation, same pattern as
    /// HYPERFOCAL_PREFETCH_WORKERS: `0` disables reuse entirely, any other
    /// integer is a budget in MB.
    public static func defaultBudget(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int64 {
        if let mb = ProcessInfo.processInfo
            .environment["HYPERFOCAL_DECODE_REUSE"].flatMap(Int64.init) {
            return mb * (1 << 20)
        }
        return Int64(physicalMemory / 8)
    }

    /// Offers a decoded frame. Kept only if it fits the remaining budget —
    /// frames are offered in stack order, and fusion consumes them in that same
    /// order, so filling from the front is the useful half to keep when the
    /// whole stack won't fit.
    public func offer(_ image: ImageBuffer, for url: URL) {
        let bytes = Int64(image.width) * Int64(image.height) * 8   // RGBA f16
        lock.lock()
        defer { lock.unlock() }
        offered += 1
        guard usedBytes + bytes <= budgetBytes, frames[url] == nil else { return }
        frames[url] = image
        usedBytes += bytes
        kept += 1
    }

    /// Removes and returns the decoded frame, if it is held. Destructive — see
    /// the type's note on peak memory.
    public func take(_ url: URL) -> ImageBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = frames.removeValue(forKey: url) else { return nil }
        usedBytes -= Int64(image.width) * Int64(image.height) * 8
        return image
    }

    /// Drops everything. The pipeline calls this when a fuse ends by any route,
    /// so a cancelled or failed fuse cannot leave gigabytes parked for the
    /// lifetime of the model's reference.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
        usedBytes = 0
    }

    /// "kept/offered frames, N MB" — for the pipeline's `-v` log line.
    public var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(kept)/\(offered) frames, \(usedBytes / (1 << 20)) MB"
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty
    }
}
