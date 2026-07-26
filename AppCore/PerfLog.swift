import Foundation

/// Wall-clock instrument for interaction latency — the timing companion to
/// `MemoryFootprint`. Behind `HYPERFOCAL_PERFLOG=1`, the model and both
/// shells stamp the milestones of a slow interaction, so "where do the
/// seconds between clicking Start Retouching and seeing the canvas go" is
/// answerable from a log instead of guesswork in Instruments.
///
/// Monotonic (`DispatchTime`), so a clock adjustment mid-measurement can't
/// invent or erase time. Three shapes, because interaction latency does not
/// all sit in one call:
///
/// - `span` brackets work that returns a value — the common case.
/// - `mark` reports the delta since the previous stamp, for milestones that
///   are points rather than intervals (a view's first draw completing).
/// - `reset` restarts the delta clock and names the interaction, so the
///   marks that follow read as offsets from the click that caused them.
///
/// Compiled on every platform: the Qt shell drives the same model, and the
/// interactions worth timing (retouch entry, project open/save) are slow on
/// all three OSes.
public enum PerfLog {
    /// `HYPERFOCAL_PERFLOG=1` gate, read once.
    public static let logging =
        ProcessInfo.processInfo.environment["HYPERFOCAL_PERFLOG"] == "1"

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// Previous stamp, for `mark`'s delta.
    private static var last: Double = 0
    /// Start of the current interaction, for `mark`'s cumulative offset.
    private static var origin: Double = 0

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Starts a named interaction: subsequent marks report both their own
    /// delta and the total elapsed since here. A no-op unless logging.
    public static func reset(_ label: String) {
        guard logging else { return }
        origin = now()
        last = origin
        write("perflog: ── \(label) ──\n")
    }

    /// Logs "perflog: <label> +X ms (Y ms total)" — X since the previous
    /// stamp, Y since the last `reset`. For milestones that arrive in their
    /// own call stack (a first draw, a completion handler).
    public static func mark(_ label: String) {
        guard logging else { return }
        let t = now()
        let delta = t - last
        last = t
        write(String(format: "perflog: %@ +%.0f ms (%.0f ms total)\n",
                     label, delta * 1000, (t - origin) * 1000))
    }

    /// Times `body` and logs "perflog: <label> = X ms". Also advances the
    /// mark clock, so a span followed by a mark doesn't double-count the
    /// span's own time. Runs `body` untouched when logging is off.
    @discardableResult
    public static func span<R>(_ label: String, _ body: () throws -> R) rethrows -> R {
        guard logging else { return try body() }
        let t0 = now()
        defer {
            let t = now()
            last = t
            write(String(format: "perflog: %@ = %.0f ms (%.0f ms total)\n",
                         label, (t - t0) * 1000, (t - origin) * 1000))
        }
        return try body()
    }
}
