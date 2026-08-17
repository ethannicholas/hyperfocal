import AppKit

/// The About window: icon, name, version (build), repository link, a
/// Third-Party Notices link, and the copyright line.
///
/// Hand-built rather than `orderFrontStandardAboutPanel` because the notices
/// live behind a link here — About is where users look for disclosures — and
/// the standard panel's credits text view can only open URLs through Launch
/// Services, which cannot reliably route a custom scheme back to *this*
/// build of the app. The Qt shell's `aboutDialog` (Main.qml) is the same
/// window, kept in sync.
enum AboutWindow {
    private static var window: NSWindow?

    /// Button targets need an object; `Actions` is that object.
    private final class Actions: NSObject {
        @objc func openRepository(_ sender: Any?) {
            NSWorkspace.shared.open(
                URL(string: "https://github.com/ethannicholas/hyperfocal")!)
        }
        @objc func showNotices(_ sender: Any?) {
            NoticesWindow.show()
        }
    }
    private static let actions = Actions()

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Hyperfocal")
        name.font = .boldSystemFont(ofSize: 16)

        let info = Bundle.main.infoDictionary ?? [:]
        let version = NSTextField(labelWithString: String(
            format: String(localized: "Version %@ (%@)"),
            info["CFBundleShortVersionString"] as? String ?? "—",
            info["CFBundleVersion"] as? String ?? "—"))
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor

        let repository = linkButton("https://github.com/ethannicholas/hyperfocal",
                                    identifier: "about.repository",
                                    action: #selector(Actions.openRepository(_:)))

        // All third-party attribution (including the Adobe DNG SDK notice)
        // lives behind this link; the DNG SDK license requires notices to be
        // retained, not displayed in About.
        let notices = linkButton(UIStrings.thirdPartyNotices,
                                 identifier: "about.third-party-notices",
                                 action: #selector(Actions.showNotices(_:)))

        let copyright = NSTextField(labelWithString:
            info["NSHumanReadableCopyright"] as? String ?? "")
        copyright.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyright.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, name, version, repository,
                                        notices, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(12, after: repository)
        stack.setCustomSpacing(12, after: notices)

        // Margins as pinning constraints in a container, not stack
        // edgeInsets: insets don't reach the window's fitting size when the
        // stack IS the content view, leaving a window with no side margins
        // at all.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])

        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: container.fittingSize),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
        panel.title = UIStrings.aboutHyperfocal
        panel.contentView = container
        panel.center()
        // The About menu item can reopen it; a released window would dangle.
        panel.isReleasedWhenClosed = false
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// A real button styled as a text link (the accessibility invariant:
    /// tappables are buttons, never bare click handlers on text).
    private static func linkButton(_ title: String, identifier: String,
                                   action: Selector) -> NSButton {
        let button = NSButton(title: title, target: actions, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.linkColor,
        ])
        button.setAccessibilityIdentifier(identifier)
        return button
    }
}
