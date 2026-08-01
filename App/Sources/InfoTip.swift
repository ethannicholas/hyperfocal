import AppKit
import SwiftUI

/// Tooltip for the (i) info icons: the same look and feel as a native help
/// tag, but shown after `UIStrings.infoTipDelayMilliseconds` instead of
/// AppKit's ~1 s default. AppKit offers no per-view tooltip delay — the only
/// knob, `NSInitialToolTipDelay`, is process-global and would drag every
/// `.help` tooltip along with the icons — so the hover is hand-rolled: a
/// tracking view arms a timer, and the tip is a borderless non-activating
/// panel that ignores mouse events. The Qt shell's InfoIcon reads the same
/// constant through `hf_info_tip_delay_ms`; ordinary tooltips on both sides
/// keep their platform's default delay.
extension View {
    func infoTip(_ text: String) -> some View {
        // The hint mirrors what `.help` would have exposed to accessibility.
        background(InfoTipTracker(text: text))
            .accessibilityHint(text)
    }
}

private struct InfoTipTracker: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> InfoTipTrackerView { InfoTipTrackerView() }

    func updateNSView(_ view: InfoTipTrackerView, context: Context) {
        view.text = text
    }
}

private final class InfoTipTrackerView: NSView {
    var text = ""
    private var delayTimer: Timer?
    private var panel: NSPanel?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        // Tracking areas fire on geometry, so sitting behind the SwiftUI
        // icon (as its .background) still sees the hover.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        dismiss()
        let delay = Double(UIStrings.infoTipDelayMilliseconds) / 1000
        delayTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                          repeats: false) { [weak self] _ in
            self?.show()
        }
    }

    override func mouseExited(with event: NSEvent) { dismiss() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The sidebar rebuilds its rows; a tip must never outlive its icon.
        if newWindow == nil { dismiss() }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        delayTimer?.invalidate()
        panel?.orderOut(nil)
    }

    private func show() {
        guard panel == nil, let window, !text.isEmpty else { return }

        // Measure with the default sizingOptions (fittingSize reports zero
        // without them), THEN neuter the sizing and wrap in a plain
        // container: as a contentView, NSHostingView's constraints re-lay-
        // out the panel after orderFront — observed blowing it up to
        // ~1750 pt tall with the pill centered inside, which put the
        // visible tip hundreds of points below the icon.
        // Two measurement passes: width from the natural pass, then height
        // re-measured with the text pinned to that width (see InfoTipLabel).
        let naturalWidth = NSHostingView(rootView: InfoTipLabel(text: text))
            .fittingSize.width
        // Zero measurements happen when the hover timer fires mid-teardown
        // (Cmd-Q with the cursor on an icon); a negative pinned width makes
        // SwiftUI log "Invalid view geometry" — skip the tip instead.
        guard naturalWidth > 16 else { return }
        let hosting = NSHostingView(rootView: InfoTipLabel(
            text: text, textWidth: min(naturalWidth, 276) - 16))
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        hosting.sizingOptions = []
        // The backdrop native help tags use: the .toolTip material, behind-
        // window blur, rounded off with a mask (a layer cornerRadius would
        // leave the vibrancy's corners square).
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .toolTip
        container.blendingMode = .behindWindow
        container.state = .active
        container.maskImage = .infoTipMask(radius: 4)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // defer: false — a deferred window has no backing until ordered in,
        // and frame changes made before that can be dropped, materializing
        // the panel at contentRect's origin (screen bottom-left) instead of
        // at the icon.
        let tip = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        tip.contentView = container
        tip.isFloatingPanel = true
        tip.level = .popUpMenu
        tip.isOpaque = false
        tip.backgroundColor = .clear
        tip.hasShadow = true
        tip.ignoresMouseEvents = true
        tip.appearance = window.appearance

        // Below the icon, left-aligned with it (where the Qt shell puts its
        // InfoTip), clamped to the screen; if the screen's bottom would
        // clip it, flip above the icon instead.
        let icon = window.convertToScreen(convert(bounds, to: nil))
        var origin = NSPoint(x: icon.minX, y: icon.minY - size.height - 4)
        if let screen = window.screen {
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width)
            origin.x = max(origin.x, screen.visibleFrame.minX)
            if origin.y < screen.visibleFrame.minY {
                origin.y = icon.maxY + 4
            }
        }
        tip.setFrameOrigin(origin)
        tip.orderFront(nil)
        panel = tip
    }

    private func dismiss() {
        delayTimer?.invalidate()
        delayTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct InfoTipLabel: View {
    let text: String
    /// nil while measuring the natural (clamped) width; the second
    /// measurement pass pins the text to that width so the reported height
    /// is for the text as it actually wraps. fittingSize alone proposes an
    /// unconstrained width — maxWidth clamps the width AFTER measuring, so
    /// wrapped tips came back with a single-line-ish height and clipped.
    var textWidth: CGFloat?

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: .labelColor))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: textWidth, alignment: .leading)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            // The fill comes from the panel's .toolTip visual-effect
            // backdrop; only the hairline edge is drawn here so it follows
            // the same rounding as the mask.
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor)))
    }
}

private extension NSImage {
    /// A stretchable rounded-rect mask for NSVisualEffectView.maskImage.
    static func infoTipMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge),
                            flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                .fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius,
                                       bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
