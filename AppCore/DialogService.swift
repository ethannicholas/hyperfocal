import Foundation

/// The modal interactions AppModel needs from its frontend — confirmations,
/// notices, and file choosers. The Mac app injects an AppKit implementation
/// (`MacDialogService`: NSAlert/NSOpenPanel/NSSavePanel, pixel-identical to
/// the dialogs the model used to present inline); the probe leaves it nil and
/// drives the existing per-prompt test overrides instead; a future non-AppKit
/// shell provides its own (see Docs/cross-platform-plan.md, Phase 0b).
///
/// All methods run on the main actor (off-main callers hop via
/// `DispatchQueue.main.sync` + `MainActor.assumeIsolated`, matching the
/// engine's GCD style). When `AppModel.dialogs` is nil every interaction
/// resolves as "cancelled" (confirms false, choosers nil, notices dropped) —
/// the safe answer for a frontend that can't ask.
@MainActor
public protocol DialogService: AnyObject {

    /// Two-button modal choice. True = the user chose `confirmTitle`
    /// (always the first/default button; `cancelTitle` is the second button,
    /// which is not always literally "Cancel" — e.g. the stack-split choice).
    func confirm(message: String, informative: String,
                 confirmTitle: String, cancelTitle: String,
                 warning: Bool) -> Bool

    /// One-button notice; returns when dismissed.
    func notify(message: String, informative: String, warning: Bool)

    /// File > Open: pick one .hyperfocal project file. Nil = cancelled.
    func chooseProjectToOpen() -> URL?

    /// New-project intake: files and/or folders, multiple. Empty = cancelled.
    func chooseFrames(message: String) -> [URL]

    /// Add Stack Folder…: folders only, multiple. Empty = cancelled.
    func chooseStackFolders(message: String) -> [URL]

    /// Sandbox re-grant: pick `root` (or an ancestor) to restore read access.
    /// Nil = cancelled. Mac-specific in spirit but harmless elsewhere.
    func chooseAccessGrant(for root: URL) -> URL?

    /// Export All / Export Aligned: pick a destination folder, with the
    /// export options (format, color space) presented alongside.
    func chooseExportDirectory(message: String) -> URL?

    /// File > Save (As): destination for the project file.
    func chooseSaveProject(directory: URL?, suggestedName: String) -> URL?

    /// Export rocking animation: destination plus the animation options
    /// (format, path, strength, duration, fps) presented alongside.
    func chooseSaveAnimation(suggestedName: String) -> URL?

    /// Export result/depth image: destination plus the export options.
    func chooseSaveExport(suggestedName: String) -> URL?
}
