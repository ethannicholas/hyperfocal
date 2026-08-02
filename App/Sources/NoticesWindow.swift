import AppKit

/// Help > Third-Party Notices: `NOTICE.md` plus every bundled license text in
/// one scrollable window.
///
/// The same files ship inside the app bundle's Resources (and, on Windows,
/// beside the executable) — carrying them with the binary is what the
/// licenses actually require. This window is the discoverable copy, so a user
/// never has to go find the source distribution to read them.
///
/// AppKit rather than a SwiftUI scene: the window is modeless, singular, and
/// opened from a menu command, which is precisely what `NSWindow` already
/// does without threading an `openWindow` environment value through a
/// `Commands` type. The Qt shell's equivalent is `Shell::noticesText` +
/// `noticesDialog` in Main.qml.
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
        text.maxSize = NSSize(width: .greatestFiniteMagnitude,
                              height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = combinedNotices()
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

    /// NOTICE.md, then each license text under its filename. The license
    /// texts are reproduced verbatim by requirement — never translated,
    /// never reflowed.
    private static func combinedNotices() -> String {
        var out = ""
        if let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            out = body
        }
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("licenses", isDirectory: true) else { return out }
        let names = ((try? FileManager.default
            .contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".txt") }
            .sorted()
        for name in names {
            guard let body = try? String(contentsOf: dir.appendingPathComponent(name),
                                         encoding: .utf8) else { continue }
            // A rule and a filename: no prose, nothing to translate.
            out += "\n\n----------------------------------------\n\(name)\n"
                + "----------------------------------------\n\n"
                + body
        }
        return out
    }
}
