import Foundation
#if canImport(Metal)
import Metal
#endif

/// Diagnostic counters for the memory instrument (`HYPERFOCAL_MEMLOG`) —
/// splits a process footprint into "Metal still holds it" vs "malloc still
/// holds it", which is the difference between a buffer leak and allocator
/// behavior. Public so the probe's --memprofile harness can read them.
public enum EngineStats {
    /// Bytes Metal currently has allocated for this process's device (live
    /// MTLBuffers and internal heaps). 0 when no Metal device exists.
    public static var metalAllocatedBytes: Int64 {
        #if canImport(Metal)
        return Int64(MetalEngine.shared?.device.currentAllocatedSize ?? 0)
        #else
        return 0
        #endif
    }

    /// malloc-zone live vs cached-free bytes (Darwin mstats).
    public static var mallocBytes: (used: Int64, free: Int64) {
        #if canImport(Darwin)
        let s = mstats()
        return (Int64(s.bytes_used), Int64(s.bytes_free))
        #else
        return (0, 0)
        #endif
    }
}
