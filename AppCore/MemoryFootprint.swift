import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Process physical-footprint readout — the same number Activity Monitor's
/// Memory column reports (phys_footprint: anonymous + compressed + IOKit,
/// not just resident pages). The instrument behind `HYPERFOCAL_MEMLOG=1`:
/// AppModel logs footprint deltas at its retention milestones so "what is
/// holding 13 GB" is answerable from a log instead of guesswork in
/// Instruments. Compiled everywhere; returns 0 where the kernel call
/// doesn't exist (non-Darwin — the Qt shells' platforms report via their
/// own tooling).
public enum MemoryFootprint {
    public static func current() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
        #else
        return 0
        #endif
    }

    /// `HYPERFOCAL_MEMLOG=1` gate, read once.
    public static let logging =
        ProcessInfo.processInfo.environment["HYPERFOCAL_MEMLOG"] == "1"

    private static var last: Int64 = 0

    /// Logs "memlog: <label> — footprint X.XX GB (Δ +Y MB)" to stderr when
    /// `HYPERFOCAL_MEMLOG=1`; a no-op otherwise. Deltas are against the
    /// previous log line, so bracketing a suspect with two marks measures it.
    public static func mark(_ label: String) {
        guard logging else { return }
        let now = current()
        let delta = now - last
        last = now
        FileHandle.standardError.write(Data(String(
            format: "memlog: %@ — footprint %.2f GB (Δ %+.0f MB)\n",
            label, Double(now) / Double(1 << 30), Double(delta) / Double(1 << 20)).utf8))
    }
}
