import AppKit

/// The Third-Party Notices window (opened from the About window): the macOS
/// slice of NOTICE.md (Packaging/notices/macos, via project.yml) rendered as
/// formatted text, then any bundled license texts verbatim. The macOS build's
/// components (DNG SDK, zlib) carry their terms inline in the notice, so no
/// standard-license .txt files ship here today — the licenses/ loop below
/// simply finds none; the Qt shell is the build that bundles those.
///
/// Carrying the notices inside the binary is what the licenses actually
/// require. This window is the discoverable copy, so a user never has to go
/// find the source distribution to read them.
///
/// AppKit rather than a SwiftUI scene: the window is modeless, singular, and
/// opened from a button, which is precisely what `NSWindow` already does
/// without threading an `openWindow` environment value through the view
/// tree. The Qt shell's equivalent is `noticesDialog` in Main.qml over
/// `Shell::noticesMarkdown`/`licensesText`.
enum NoticesWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // The standard "text view in a scroll view" wiring: the view grows
        // vertically with its content while its container tracks the scroll
        // view's width, so the text wraps instead of scrolling sideways.
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.textStorage?.setAttributedString(
            attributedNotices(notice: bundledNotice(), licenses: bundledLicenses()))
        scroll.documentView = text

        let panel = NSWindow(contentRect: frame,
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered,
                             defer: false)
        panel.title = UIStrings.thirdPartyNotices
        panel.contentView = scroll
        panel.center()
        // Menu commands can reopen it; a released window would dangle.
        panel.isReleasedWhenClosed = false
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Bundle reads

    private static func bundledNotice() -> String {
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md"),
              let body = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return body
    }

    private static func bundledLicenses() -> [(name: String, body: String)] {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("licenses", isDirectory: true) else { return [] }
        let names = ((try? FileManager.default
            .contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".txt") }
            .sorted()
        return names.compactMap { name in
            guard let body = try? String(contentsOf: dir.appendingPathComponent(name),
                                         encoding: .utf8) else { return nil }
            return (name: name, body: body)
        }
    }

    // MARK: - Formatting (pure — bundle-free so it can be exercised headless)

    /// Rendered NOTICE.md, then each license text under its filename. The
    /// license texts are reproduced verbatim by requirement — never
    /// translated, never reflowed, and never fed through the Markdown
    /// renderer (it would eat their hard line breaks).
    static func attributedNotices(notice: String,
                                  licenses: [(name: String, body: String)]) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: renderedMarkdown(notice))
        let mono: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        for license in licenses {
            // A rule and a filename: no prose, nothing to translate.
            out.append(NSAttributedString(
                string: "\n\n----------------------------------------\n\(license.name)\n"
                    + "----------------------------------------\n\n",
                attributes: mono))
            out.append(NSAttributedString(string: license.body, attributes: mono))
        }
        return out
    }

    /// Markdown → styled text via Foundation's parser: block structure
    /// arrives as `PresentationIntent` runs, inline emphasis as
    /// `InlinePresentationIntent`, and this walk maps both onto fonts and
    /// paragraph styles (headers, block quotes, lists, code, links).
    static func renderedMarkdown(_ source: String) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 13)
        let fallback: [NSAttributedString.Key: Any] = [
            .font: body, .foregroundColor: NSColor.labelColor,
        ]
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: fallback)
        }

        let out = NSMutableAttributedString()
        var previousIntent: PresentationIntent?
        for run in parsed.runs {
            var font = body
            var color = NSColor.labelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8

            var listMarker: String?
            var skipRun = false
            if let intent = run.presentationIntent {
                var ordinal: Int?
                var ordered = false
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let sizes: [CGFloat] = [20, 16, 14]
                        font = .boldSystemFont(ofSize: sizes[min(level, 3) - 1])
                        paragraph.paragraphSpacingBefore = level == 1 ? 4 : 14
                        paragraph.paragraphSpacing = 6
                    case .blockQuote:
                        color = .secondaryLabelColor
                        paragraph.firstLineHeadIndent = 16
                        paragraph.headIndent = 16
                    case .codeBlock:
                        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                    case .listItem(let itemOrdinal):
                        ordinal = itemOrdinal
                        paragraph.firstLineHeadIndent = 4
                        paragraph.headIndent = 18
                        paragraph.paragraphSpacing = 3
                    case .orderedList:
                        ordered = true
                    case .thematicBreak:
                        // Rules exist in the source to split major sections;
                        // the header spacing already reads as the break.
                        skipRun = true
                    default:
                        break
                    }
                }
                if let ordinal { listMarker = ordered ? "\(ordinal). " : "•  " }
            }
            if skipRun { continue }

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                }
                if inline.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if inline.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            // NOTICE.md's relative links (LICENSE, licenses/, vendored paths)
            // point into the source tree, not the bundle; only real URLs are
            // followable.
            if let link = run.link, let scheme = link.scheme,
               scheme == "http" || scheme == "https" {
                attributes[.link] = link
            }

            // The parser strips the newlines between blocks; reinsert one at
            // every block boundary so paragraph styles stay per-paragraph.
            let newBlock = run.presentationIntent != previousIntent
            if newBlock && out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            if newBlock, let listMarker {
                out.append(NSAttributedString(string: listMarker, attributes: attributes))
            }
            out.append(NSAttributedString(
                string: String(parsed.characters[run.range]), attributes: attributes))
            previousIntent = run.presentationIntent
        }
        return out
    }
}
