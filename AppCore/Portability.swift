// Portability stand-ins for Apple-only logging (cross-platform plan):
// on platforms without the os module, Logger keeps the exact call shape
// AppCore uses — including `privacy:` interpolations, which are ignored —
// and writes to stderr. Compiled nowhere on Apple platforms.
#if !canImport(os)
import Foundation

enum LogPrivacy {
    case `public`, `private`
}

/// Message type mirroring OSLogMessage's interpolation surface (the
/// subset AppCore uses).
struct LogMessage: ExpressibleByStringInterpolation {
    let text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: Interpolation) { text = stringInterpolation.out }

    struct Interpolation: StringInterpolationProtocol {
        var out = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { out += literal }
        mutating func appendInterpolation<T>(_ value: T) { out += "\(value)" }
        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy) {
            out += "\(value)"
        }
    }
}

struct Logger {
    let category: String

    init(subsystem: String, category: String) { self.category = category }

    func debug(_ message: LogMessage) { emit("debug", message) }
    func info(_ message: LogMessage) { emit("info", message) }
    func notice(_ message: LogMessage) { emit("notice", message) }
    func warning(_ message: LogMessage) { emit("warning", message) }
    func error(_ message: LogMessage) { emit("error", message) }
    func fault(_ message: LogMessage) { emit("fault", message) }

    private func emit(_ level: String, _ message: LogMessage) {
        FileHandle.standardError.write(
            Data("[\(category)] \(level): \(message.text)\n".utf8))
    }
}
#endif
