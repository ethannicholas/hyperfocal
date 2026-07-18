import Foundation
#if canImport(ImageIO)
import ImageIO
#else
import CImaging
#endif

/// Splits a session's frames into stacks by capture-time gaps. Stackers shoot
/// sessions — ten stacks of 50–200 frames into one folder — and the bursts are
/// separated by seconds of repositioning while frames within a burst are well
/// under a second apart. EXIF `DateTimeOriginal` is read from the file header
/// only (no pixel decode), so scanning hundreds of frames is cheap.
public enum StackSplitter {

    /// Default gap between bursts, in seconds. Frames from a focus rail arrive
    /// well under a second apart; repositioning between stacks takes longer.
    public static let defaultGap: TimeInterval = 10

    /// EXIF capture time (DateTimeOriginal + subseconds), or nil if the file
    /// carries none.
    public static func captureDate(of url: URL) -> Date? {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let date = exifFormatter.date(from: stamp) else { return nil }
        if let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
           let fraction = Double("0.\(subsec)") {
            return date.addingTimeInterval(fraction)
        }
        return date
        #else
        // exiv2 reads DateTimeOriginal (+ SubSecTimeOriginal) and returns it as
        // a UTC-naive epoch — matching exifFormatter's GMT, timezone-free basis.
        var epoch: Double = 0
        guard hf_exif_capture_epoch(url.path, &epoch) == hf_ok else { return nil }
        return Date(timeIntervalSince1970: epoch)
        #endif
    }

    /// Fusion frame order for a stack: capture time (name as tiebreaker),
    /// because filename order breaks when the camera's file counter rolls
    /// over mid-stack (DSC_9999 → DSC_0001). Name order when
    /// `byCaptureTime` is off — or when *any* frame is undated: like
    /// split(), a wrong reorder is worse than none.
    public static func ordered(urls: [URL], byCaptureTime: Bool) -> [URL] {
        ordered(urls: urls,
                dates: byCaptureTime ? urls.map { captureDate(of: $0) } : [],
                byCaptureTime: byCaptureTime)
    }

    /// Pure ordering logic (`dates` parallel to `urls`), separated for tests
    /// and for callers that already read the dates.
    public static func ordered(urls: [URL], dates: [Date?],
                               byCaptureTime: Bool) -> [URL] {
        let nameOrder = { (a: URL, b: URL) in
            a.lastPathComponent < b.lastPathComponent
        }
        guard byCaptureTime, urls.count == dates.count else {
            return urls.sorted(by: nameOrder)
        }
        var stamped = [(url: URL, date: Date)]()
        for (url, date) in zip(urls, dates) {
            guard let date else { return urls.sorted(by: nameOrder) }
            stamped.append((url, date))
        }
        return stamped.sorted {
            $0.date != $1.date ? $0.date < $1.date : nameOrder($0.url, $1.url)
        }.map(\.url)
    }

    /// Why a stack's fusion order deserves a warning, if it does.
    public enum OrderIssue: Equatable {
        /// Capture-time order and filename order disagree. The fused order
        /// (capture time) is still correct for a rolled-over file counter —
        /// but disagreement is also the signature of a shuffled or
        /// interleaved load (two stacks' frames in one folder), which fuses
        /// to garbage silently.
        case mismatch
        /// No complete set of capture times: filename order was the
        /// fallback, with nothing else saying capture ordering wasn't
        /// available.
        case undated
    }

    /// Sanity check for the order a stack will fuse in. Nil in name-order
    /// mode — that's an explicit setting, not a silent fallback.
    public static func orderIssue(urls: [URL], dates: [Date?],
                                  byCaptureTime: Bool) -> OrderIssue? {
        guard byCaptureTime, urls.count > 1 else { return nil }
        guard urls.count == dates.count, !dates.contains(nil) else {
            return .undated
        }
        let byName = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ordered(urls: urls, dates: dates, byCaptureTime: true) == byName
            ? nil : .mismatch
    }

    /// Reads capture times and groups the frames at gaps larger than `gap`.
    /// If *any* frame lacks a timestamp the whole list stays one group — a
    /// wrong split is worse than no split.
    public static func split(urls: [URL], gap: TimeInterval = defaultGap,
                             orderByCaptureTime: Bool = true) -> [[URL]] {
        split(urls: urls, dates: urls.map { captureDate(of: $0) }, gap: gap,
              orderByCaptureTime: orderByCaptureTime)
    }

    /// Pure grouping logic (`dates` parallel to `urls`), separated for tests.
    /// Frames are ordered by capture time (name as tiebreaker) and cut where
    /// consecutive captures are more than `gap` apart. Groups come back in
    /// capture order by default (focus order that survives filename-counter
    /// rollover); `orderByCaptureTime: false` re-sorts each group by name.
    public static func split(urls: [URL], dates: [Date?], gap: TimeInterval,
                             orderByCaptureTime: Bool = true) -> [[URL]] {
        guard urls.count > 1, urls.count == dates.count else { return [urls] }
        var stamped = [(url: URL, date: Date)]()
        for (url, date) in zip(urls, dates) {
            guard let date else { return [urls] }  // undated frame ⇒ don't split
            stamped.append((url, date))
        }
        stamped.sort {
            $0.date != $1.date ? $0.date < $1.date
                               : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        var groups = [[URL]]()
        var current = [stamped[0].url]
        for i in 1..<stamped.count {
            if stamped[i].date.timeIntervalSince(stamped[i - 1].date) > gap {
                groups.append(current)
                current = []
            }
            current.append(stamped[i].url)
        }
        groups.append(current)
        return orderByCaptureTime
            ? groups
            : groups.map { $0.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    }

    /// EXIF date encoding ("2026:07:06 14:03:21"). Timezone-naive by design:
    /// only gaps between frames matter, and all frames of a session share
    /// whatever zone the camera was set to.
    static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
