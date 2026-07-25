import Foundation

/// The shared layer's localized-string seam.
///
/// On Apple this is `NSLocalizedString` against the main bundle — the macOS
/// app's `Localizable.xcstrings`, exactly as before; headless Apple consumers
/// (CLI, probe) have no catalog and get the English key back.
///
/// Off Apple there is no bundle catalog to read, and every string AppCore
/// hands the Qt shell — status, errors, dialogs, undo names — would otherwise
/// be English regardless of the shell's own translations. There it resolves
/// against `GeneratedStrings`, flattened from the same catalog by
/// `Scripts/gen-translations.py`.
///
/// `comment:` is retained (and ignored) so call sites read like the
/// `NSLocalizedString` they replaced and stay greppable for the coverage gate.
public func localizedString(_ key: String, comment: String = "") -> String {
    #if canImport(CoreGraphics)
    return NSLocalizedString(key, comment: comment)
    #else
    return PortableStrings.localized(key)
    #endif
}

/// The generated catalog's runtime.
///
/// Compiled on every platform, not just the ones that use it: gating it out
/// on Apple would leave the resolver and the tag matching testable only on
/// the machines where a regression is hardest to notice. `retouch-probe`
/// exercises it directly on macOS.
public enum PortableStrings {

    /// The language tags the generated catalog ships.
    public static var languages: [String] { GeneratedStrings.languages }

    /// The tags to try for a locale identifier, most specific first:
    /// `pt_BR` → `["pt-BR", "pt"]`, `zh_CN` → `["zh-CN", "zh-Hans", "zh"]`,
    /// `de_DE.UTF-8` → `["de-DE", "de"]`.
    public static func candidateTags(for identifier: String) -> [String] {
        // Env-style identifiers carry an encoding suffix ("de_DE.UTF-8") and
        // may use either separator depending on the platform's Foundation.
        let base = identifier.split(separator: ".").first.map(String.init)
            ?? identifier
        let normalized = base.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return [] }

        var tags: [String] = []
        if parts.count > 1 { tags.append(normalized) }
        // Chinese needs a script, which the region implies but never states:
        // zh_CN is Simplified, zh_TW Traditional. Without this, a zh_CN
        // desktop matches no shipped tag and falls back to English.
        if language == "zh", parts.count > 1 {
            switch parts[1] {
            case "CN", "SG", "Hans": tags.append("zh-Hans")
            case "TW", "HK", "MO", "Hant": tags.append("zh-Hant")
            default: break
            }
        }
        tags.append(language)

        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    /// The flat table for one language tag, or nil when it ships none.
    public static func table(for language: String) -> [String: String]? {
        guard let blob = GeneratedStrings.blob(for: language) else { return nil }
        // Positional key/value pairs separated by U+0001 — see the generator
        // for why this is one literal rather than a dictionary.
        let fields = blob.split(separator: "\u{1}",
                                omittingEmptySubsequences: false)
        var table = [String: String](minimumCapacity: fields.count / 2)
        var i = 0
        while i + 1 < fields.count {
            table[String(fields[i])] = String(fields[i + 1])
            i += 2
        }
        return table
    }

    /// The table for the running process, chosen once.
    ///
    /// `HYPERFOCAL_LANG` overrides the system locale (the CLI/selftest hook,
    /// and how the probe checks a language it isn't running under). An empty
    /// table means English — every lookup falls through to its key.
    public static let current: [String: String] = {
        let override = ProcessInfo.processInfo.environment["HYPERFOCAL_LANG"]
        let identifier = override.flatMap { $0.isEmpty ? nil : $0 }
            ?? Locale.current.identifier
        for tag in candidateTags(for: identifier) {
            if let table = table(for: tag) { return table }
        }
        return [:]
    }()

    /// The localized value, or the key itself — an English word beats an
    /// empty control.
    public static func localized(_ key: String) -> String {
        current[key] ?? key
    }
}
