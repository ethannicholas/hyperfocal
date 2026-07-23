import AppKit
import UniformTypeIdentifiers
import HyperfocalKit

// The option enums stayed nested in AppModel when these views moved out of
// it (Phase 0b dialog seam); alias them so the moved code reads unchanged.
private typealias ExportFormat = AppModel.ExportFormat
private typealias ExportColorSpace = AppModel.ExportColorSpace
private typealias AnimationFormat = AppModel.AnimationFormat
private typealias AnimationPath = AppModel.AnimationPath
private typealias AnimationStrength = AppModel.AnimationStrength
private typealias AnimationDuration = AppModel.AnimationDuration
private typealias AnimationFPS = AppModel.AnimationFPS

/// AppKit implementation of DialogService — the NSAlert/NSOpenPanel/
/// NSSavePanel presentations AppModel used to run inline, moved behind the
/// dialog seam (Docs/cross-platform-plan.md, Phase 0b) byte-for-byte so
/// behavior is unchanged. Holds the model weakly: the accessory views bind
/// panel options (export format, animation settings) to the same persisted
/// settings the engine reads.
final class MacDialogService: DialogService {

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func confirm(message: String, informative: String,
                 confirmTitle: String, cancelTitle: String,
                 warning: Bool) -> Bool {
        let alert = NSAlert()
        if warning { alert.alertStyle = .warning }
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func notify(message: String, informative: String, warning: Bool) {
        let alert = NSAlert()
        if warning { alert.alertStyle = .warning }
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    func openDownloadPage(message: String, informative: String, url: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn, let link = URL(string: url) {
            NSWorkspace.shared.open(link)
        }
    }

    func chooseProjectToOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: ProjectStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseFrames(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    func chooseStackFolders(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    func chooseAccessGrant(for root: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.message = String(localized: "Grant access to “\(root.lastPathComponent)” — \(root.path)")
        panel.prompt = String(localized: "Grant Access")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseExportDirectory(message: String) -> URL? {
        guard let model else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.message = message
        panel.accessoryView = ExportOptionsView(model: model, panel: nil)
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseSaveProject(directory: URL?, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ProjectStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        if let directory { panel.directoryURL = directory }
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseSaveAnimation(suggestedName: String) -> URL? {
        guard let model else { return nil }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: model.animationFormat.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = suggestedName
        panel.accessoryView = AnimationOptionsView(model: model, panel: panel)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseSaveExport(suggestedName: String) -> URL? {
        guard let model else { return nil }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: model.exportFormat.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = suggestedName
        panel.accessoryView = ExportOptionsView(model: model, panel: panel)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Pickers for the rocking-animation save panel (format, path, strength,
/// duration, frame rate) — same no-Auto-Layout recipe as ExportOptionsView
/// (the remote panel polls constraint-based fitting sizes every frame; fixed
/// frames don't). Switching format retargets the panel so the filename
/// extension follows.
@MainActor
final class AnimationOptionsView: NSView {
    private weak var model: AppModel?
    private weak var panel: NSSavePanel?
    private let formatPopup = NSPopUpButton()
    private let pathPopup = NSPopUpButton()
    private let strengthPopup = NSPopUpButton()
    private let durationPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()

    init(model: AppModel, panel: NSSavePanel?) {
        self.model = model
        self.panel = panel
        super.init(frame: .zero)

        func configure<Choice: DisplayNamed>(
            _ popup: NSPopUpButton, _ kind: Choice.Type, selected: Choice,
            id: String, tip: String
        ) {
            for choice in Choice.allCases {
                popup.addItem(withTitle: choice.displayName)
            }
            popup.selectItem(withTitle: selected.displayName)
            popup.target = self
            popup.action = #selector(changed(_:))
            popup.setAccessibilityIdentifier(id)
            popup.toolTip = tip
        }
        configure(formatPopup, AnimationFormat.self, selected: model.animationFormat,
                  id: "export.animation-format",
                  tip: String(localized: "MP4 plays once unless the player is told to loop (no video format carries a loop flag players honor). GIF loops forever everywhere, at the cost of larger files and reduced colors."))
        configure(pathPopup, AnimationPath.self, selected: model.animationPath,
                  id: "export.animation-path",
                  tip: String(localized: "How the viewpoint moves. Rocking sweeps side to side (or up and down); Circle orbits, which reads most strongly 3D — no structure can hide parallel to the motion."))
        configure(strengthPopup, AnimationStrength.self, selected: model.animationStrength,
                  id: "export.animation-strength",
                  tip: String(localized: "How far the view moves: peak parallax at the depth extremes, as a fraction of the video width (Subtle 0.5%, Medium 1%, Strong 2%)."))
        configure(durationPopup, AnimationDuration.self, selected: model.animationDuration,
                  id: "export.animation-duration",
                  tip: String(localized: "One full cycle of the motion; the file loops seamlessly."))
        configure(fpsPopup, AnimationFPS.self, selected: model.animationFPS,
                  id: "export.animation-fps",
                  tip: String(localized: "Frames per second. 30 suits sharing; 60 is silkier and larger; 24 is filmic."))

        // Container-ish options first, motion options last. (No depth
        // direction option on purpose: negated disparity is exactly a
        // half-cycle phase shift of these symmetric loops — provably
        // invisible; see RockingAnimation.Options.)
        let rows: [(String, NSControl)] = [
            (String(localized: "Format:"), formatPopup),
            (String(localized: "Frame rate:"), fpsPopup),
            (String(localized: "Duration:"), durationPopup),
            (String(localized: "Path:"), pathPopup),
            (String(localized: "Strength:"), strengthPopup),
        ]
        let labels = rows.map { NSTextField(labelWithString: $0.0) }
        for label in labels { label.sizeToFit() }
        for (_, popup) in rows { popup.sizeToFit() }
        let pad: CGFloat = 20, vpad: CGFloat = 12
        let gap: CGFloat = 8, rowGap: CGFloat = 6
        let labelW = labels.map(\.frame.width).max() ?? 0
        let popupW = rows.map(\.1.frame.width).max() ?? 0
        let rowH = rows.map(\.1.frame.height).max() ?? 25
        let count = CGFloat(rows.count)
        let size = NSSize(width: pad + labelW + gap + popupW + pad,
                          height: vpad + rowH * count + rowGap * (count - 1) + vpad)
        for (index, (label, row)) in zip(labels, rows).enumerated() {
            let popup = row.1
            let y = size.height - vpad - rowH - CGFloat(index) * (rowH + rowGap)
            popup.frame = NSRect(x: pad + labelW + gap, y: y,
                                 width: popupW, height: rowH)
            label.frame.origin = NSPoint(
                x: pad + labelW - label.frame.width,
                y: y + (rowH - label.frame.height) / 2)
            addSubview(label)
            addSubview(popup)
        }
        frame = NSRect(origin: .zero, size: size)
        for view in subviews {
            view.autoresizingMask = [.maxXMargin, .minYMargin]
        }
        autoresizingMask = .width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Selection → case by position: popup titles are localized display
    /// names, so they can no longer round-trip through rawValue.
    private func selected<Choice: DisplayNamed>(
        _ popup: NSPopUpButton, _ kind: Choice.Type) -> Choice? {
        let index = popup.indexOfSelectedItem
        let all = Array(Choice.allCases)
        guard all.indices.contains(index) else { return nil }
        return all[index]
    }

    @objc private func changed(_ sender: NSPopUpButton) {
        guard let model else { return }
        switch sender {
        case formatPopup:
            guard let format = selected(sender, AnimationFormat.self) else { return }
            model.animationFormat = format
            if let type = UTType(filenameExtension: format.fileExtension) {
                panel?.allowedContentTypes = [type]
            }
        case pathPopup:
            model.animationPath = selected(sender, AnimationPath.self) ?? model.animationPath
        case strengthPopup:
            model.animationStrength = selected(sender, AnimationStrength.self) ?? model.animationStrength
        case durationPopup:
            model.animationDuration = selected(sender, AnimationDuration.self) ?? model.animationDuration
        case fpsPopup:
            model.animationFPS = selected(sender, AnimationFPS.self) ?? model.animationFPS
        default:
            break
        }
    }
}

/// Format + color-space pickers hosted inside the export dialogs
/// (Photoshop-style: the options live next to the decision they affect,
/// not in the main window). Bound to the same persisted settings the
/// engine reads, so dialogs remember the last choice; on a save panel,
/// switching format retargets the allowed content type so the filename
/// extension follows.
@MainActor
final class ExportOptionsView: NSView {
    private weak var model: AppModel?
    private weak var panel: NSSavePanel?
    private let formatPopup = NSPopUpButton()
    private let spacePopup = NSPopUpButton()

    /// What the color-space popup reads while DNG is selected: DNG
    /// always carries linear P3, and a disabled popup frozen on the
    /// previous choice would read as "DNG uses sRGB and you can't
    /// change it".
    private static let dngSpaceTitle = String(localized: "Linear Display P3")

    init(model: AppModel, panel: NSSavePanel?) {
        self.model = model
        self.panel = panel
        super.init(frame: .zero)
        for format in ExportFormat.allCases {
            formatPopup.addItem(withTitle: format.displayName)
        }
        formatPopup.selectItem(withTitle: model.exportFormat.displayName)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        formatPopup.setAccessibilityIdentifier("export.format")
        for space in ExportColorSpace.allCases {
            spacePopup.addItem(withTitle: space.displayName)
        }
        spacePopup.target = self
        spacePopup.action = #selector(spaceChanged)
        spacePopup.setAccessibilityIdentifier("export.color-space")
        spacePopup.toolTip = String(localized: "The pipeline works in Display P3. sRGB is the safe default for sharing; Display P3 keeps the full working gamut; ProPhoto suits further heavy editing. DNG always carries the full P3 gamut as linear raw.")

        // Fixed frames, NO Auto Layout: sandboxed save panels are remote,
        // and the bridge polls the accessory's constraint-based fitting
        // size every frame — a baseline-aligned NSGridView never
        // converges, so an idle panel re-solved constraints forever
        // (~30% CPU). Plain frames give the bridge a constant answer.
        // Width is computed with the widest spacePopup contents (the DNG
        // placeholder) present so refresh() never changes any frame.
        let labelFormat = NSTextField(labelWithString: String(localized: "Format:"))
        let labelSpace = NSTextField(labelWithString: String(localized: "Color space:"))
        spacePopup.addItem(withTitle: Self.dngSpaceTitle)
        for control in [labelFormat, labelSpace, formatPopup, spacePopup] {
            control.sizeToFit()
        }
        spacePopup.removeItem(at: spacePopup.numberOfItems - 1)
        let pad: CGFloat = 20, vpad: CGFloat = 12
        let gap: CGFloat = 8, rowGap: CGFloat = 6
        let labelW = max(labelFormat.frame.width, labelSpace.frame.width)
        let popupW = max(formatPopup.frame.width, spacePopup.frame.width)
        let rowH = max(formatPopup.frame.height, spacePopup.frame.height)
        let size = NSSize(width: pad + labelW + gap + popupW + pad,
                          height: vpad + rowH * 2 + rowGap + vpad)
        func place(_ label: NSTextField, _ popup: NSPopUpButton, rowFromTop: Int) {
            let y = size.height - vpad - rowH - CGFloat(rowFromTop) * (rowH + rowGap)
            popup.frame = NSRect(x: pad + labelW + gap, y: y,
                                 width: popupW, height: rowH)
            label.frame.origin = NSPoint(
                x: pad + labelW - label.frame.width,
                y: y + (rowH - label.frame.height) / 2)
            addSubview(label)
            addSubview(popup)
        }
        place(labelFormat, formatPopup, rowFromTop: 0)
        place(labelSpace, spacePopup, rowFromTop: 1)
        // Frame FIRST, masks after: autoresizing redistributes margins on
        // every resize, so growing the view from its .zero init frame
        // with flexible masks already set scrambles the placement (all
        // controls piled up at one spot). Rigid placement + final frame,
        // THEN the masks that pin the block top-left while the panel
        // stretches the accessory to its own width and height.
        frame = NSRect(origin: .zero, size: size)
        for view in subviews {
            view.autoresizingMask = [.maxXMargin, .minYMargin]
        }
        // Flexible width on the accessory ITSELF: a rigid view can't be
        // stretched by the panel, which centers it instead — the whole
        // block floated to the middle regardless of the internal layout.
        autoresizingMask = .width
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func formatChanged() {
        let all = ExportFormat.allCases
        guard let model, all.indices.contains(formatPopup.indexOfSelectedItem)
        else { return }
        let format = all[formatPopup.indexOfSelectedItem]
        model.exportFormat = format
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel?.allowedContentTypes = [type]
        }
        refresh()
    }

    @objc private func spaceChanged() {
        let all = ExportColorSpace.allCases
        guard let model, all.indices.contains(spacePopup.indexOfSelectedItem)
        else { return }
        model.exportColorSpace = all[spacePopup.indexOfSelectedItem]
    }

    private func refresh() {
        guard let model else { return }
        let dng = model.exportFormat == .dng
        spacePopup.isEnabled = !dng
        if dng {
            if spacePopup.item(withTitle: Self.dngSpaceTitle) == nil {
                spacePopup.addItem(withTitle: Self.dngSpaceTitle)
            }
            spacePopup.selectItem(withTitle: Self.dngSpaceTitle)
        } else {
            if let placeholder = spacePopup.item(withTitle: Self.dngSpaceTitle) {
                spacePopup.removeItem(at: spacePopup.index(of: placeholder))
            }
            spacePopup.selectItem(withTitle: model.exportColorSpace.displayName)
        }
    }
}
