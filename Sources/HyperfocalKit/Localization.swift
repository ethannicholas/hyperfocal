import Foundation

/// The shared layer's localized-string seam.
///
/// On Apple this is `NSLocalizedString` against the main bundle — the macOS
/// app's `Localizable.xcstrings`; headless Apple consumers
/// (CLI, probe) have no catalog and get the English key back.
///
/// Off Apple there is no bundle catalog to read, and every string AppCore
/// hands the Qt shell — status, errors, dialogs, undo names — would otherwise
/// be English regardless of the shell's own translations. There it resolves
/// against `GeneratedStrings`, flattened from the same catalog by
/// `Scripts/gen-translations.py`.
///
/// A language chosen explicitly by the host (`PortableStrings.setLanguage`)
/// wins on every platform, Apple included: the Qt shell decides the UI
/// language for its own half and hands the same tag down here, so the two
/// halves of one window cannot pick differently. Nothing in the macOS app
/// calls it, so that shell keeps reading its bundle catalog.
///
/// `comment:` is retained (and ignored) so call sites read like
/// `NSLocalizedString` and stay greppable for the coverage gate.
public func localizedString(_ key: String, comment: String = "") -> String {
    if let table = PortableStrings.explicitTable { return table[key] ?? key }
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

    /// The language the host chose for this process, or nil while the
    /// process is following its locale (`HYPERFOCAL_LANG` / the system).
    ///
    /// Set once at startup, before any UI exists, and only read afterwards —
    /// hence a plain static rather than a lock.
    private static var explicit: [String: String]?

    /// The explicitly chosen table, for `localizedString`'s Apple branch.
    public static var explicitTable: [String: String]? { explicit }

    /// Adopt `tag` — a catalog tag or any locale identifier (`de`, `pt-BR`,
    /// `zh_CN`) — as this process's language, for every `localizedString`
    /// from here on. Call before the first string is read: the shared
    /// strings are lazy globals, so whatever language is in force when one is
    /// first touched is the language it keeps.
    ///
    /// Returns false when the catalog ships nothing for the tag. The override
    /// is installed either way (an empty table means English, every lookup
    /// falling through to its key): a host that asked for a language must not
    /// silently end up in a *different* one via the system locale.
    ///
    /// A nil `tag` clears the choice and goes back to following the locale.
    @discardableResult
    public static func setLanguage(_ tag: String?) -> Bool {
        guard let tag else {
            explicit = nil
            return false
        }
        for candidate in candidateTags(for: tag) {
            if let table = table(for: candidate) {
                explicit = table
                return true
            }
        }
        explicit = [:]
        return false
    }

    /// The localized value, or the key itself — an English word beats an
    /// empty control.
    public static func localized(_ key: String) -> String {
        (explicit ?? current)[key] ?? key
    }
}
