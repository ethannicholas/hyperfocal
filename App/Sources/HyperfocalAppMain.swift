import SwiftUI
import HyperfocalKit

/// Quit gate: a project holds retouch edits that can't be recomputed, and
/// writing it automatically at quit proved too slow — so termination asks
/// for confirmation when unsaved work exists.
///
/// Also disables window tabbing: tabs would show several scenes all bound
/// to the one shared AppModel — not a multi-project feature, just the same
/// project rendered twice. (The View menu used to be stripped wholesale for
/// its tab items, but disabling tabbing removes them at the source, and the
/// stripper raced SwiftUI's menu reinstalls — a flickering View menu during
/// fuses — once zoom commands moved in.)
/// Window-delegate proxy: SwiftUI installs its own delegate on the scene's
/// window, so the close veto wraps it — windowShouldClose is ours, every
/// other delegate callback forwards untouched.
final class WindowCloseGate: NSObject, NSWindowDelegate {
    weak var wrapped: (any NSWindowDelegate)?
    var shouldClose: (NSWindow) -> Bool = { _ in true }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (wrapped?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        wrapped
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose(sender)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet { flushPendingOpens() }
    }
    /// Finder can deliver open-file events before SwiftUI's onAppear wires
    /// the model (double-clicking a project launches the app); they queue
    /// here and flush once the model exists.
    private var pendingOpenURLs = [URL]()

    /// The red close button is a quit for a single-window app, and the
    /// unsaved-work question must be answered BEFORE the window goes away:
    /// without the veto, the window closed first and the quit confirmation
    /// arrived after it — with nothing left to cancel back to. The gate
    /// asks in windowShouldClose; an approved close then terminates without
    /// asking again (closeApproved short-circuits applicationShouldTerminate).
    private let closeGate = WindowCloseGate()  // window.delegate is weak
    private var closeApproved = false

    /// Called from the main window's onAppear (the window exists by then).
    func installCloseGate() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = NSApp.windows.first(where: { $0.delegate !== self.closeGate
                      && !($0.delegate is WindowCloseGate) && $0.isVisible }) else { return }
            self.closeGate.wrapped = window.delegate
            self.closeGate.shouldClose = { [weak self] _ in
                guard let self else { return true }
                return MainActor.assumeIsolated {
                    guard let model = self.model else { return true }
                    guard model.confirmTermination() == .terminateNow else { return false }
                    self.closeApproved = true
                    // Terminate explicitly: relying on last-window-closed
                    // would leave a headless app if Settings happens to be
                    // open.
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return true
                }
            }
            window.delegate = self.closeGate
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closeApproved { return .terminateNow }
        return MainActor.assumeIsolated { model?.confirmTermination() ?? .terminateNow }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs += urls
        flushPendingOpens()
    }

    private func flushPendingOpens() {
        guard model != nil, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        MainActor.assumeIsolated { model?.openExternal(urls: urls) }
    }
}

@main
struct HyperfocalApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A Window scene, not a WindowGroup: there is exactly one project and
        // one model, so there must be exactly one window. With a WindowGroup,
        // double-clicking a .hyperfocal while the app runs made SwiftUI spawn
        // a second window for the open event (the delegate handles the file;
        // the extra window was pure scene plumbing) — and declining external
        // events at the scene level instead broke double-click-to-LAUNCH,
        // which parked the app windowless. Window sidesteps both.
        Window("Hyperfocal", id: "main") {
            ContentView()
                .environmentObject(model)
                // Titlebar shows the open project like a document window
                // (Save writes back to it, so the user should see which
                // file that is).
                .navigationTitle(model.projectURL.map {
                    $0.deletingPathExtension().lastPathComponent
                } ?? "Hyperfocal")
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.installCloseGate()
                    UITestSupport.activate(model)
                }
        }
        .commands {
            // Standard about panel (icon/name/version/copyright come from the
            // bundle) plus a credits blurb carrying the Adobe-required DNG
            // attribution and a link to the repository.
            CommandGroup(replacing: .appInfo) {
                Button("About Hyperfocal") {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                    let credits = NSMutableAttributedString(
                        string: "https://github.com/ethannicholas/hyperfocal",
                        attributes: attributes.merging(
                            [.link: URL(string: "https://github.com/ethannicholas/hyperfocal")!],
                            uniquingKeysWith: { _, new in new }))
                    credits.append(NSAttributedString(
                        string: """


                        Includes the Adobe DNG SDK — DNG technology under \
                        license by Adobe Systems Incorporated. See NOTICE.md \
                        in the source distribution for all third-party credits.
                        """,
                        attributes: attributes))
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [.credits: credits])
                }
            }
            CommandGroup(replacing: .newItem) {
                // Same action as the empty state's "Open Folder…" button,
                // deliberately named differently: from the File menu the
                // mental model is starting a project; from the empty window
                // it's pointing the app at a folder of frames.
                Button("New Project…") { model.openFrames() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") { model.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Add Stack Folder…") { model.addStackFolderPanel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.phase.isRunning)
                Button("Close Stack") { model.closeSelectedStack() }
                    .disabled(model.phase.isRunning || model.selectedStackID == nil)
                Button("Close Project") { model.closeProject() }
                    .disabled(model.phase.isRunning || model.stacks.isEmpty)
                Divider()
                // Enabled whenever there's anything at all to save: unfused
                // stacks persist fine, and `phase` only mirrors the selected
                // stack — keying on it wrongly disabled Save in multi-stack
                // projects whenever an unfused stack happened to be selected.
                // Save writes back to the project's file; a never-saved
                // project falls through to the Save As panel (no ellipsis:
                // the common case shows no dialog).
                Button("Save Project") { model.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.stacks.isEmpty || model.phase.isRunning)
                Button("Save Project As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.stacks.isEmpty || model.phase.isRunning)
                Button("Export Result…") { model.exportResult() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.canExport)
                Button("Export Aligned Frames…") { model.exportAlignedFramesPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportAligned)
                Button("Export Rocking Animation…") { model.exportAnimation() }
                    .disabled(!model.canAnimate)
            }
            // Edit > Undo/Redo, mode-scoped (we don't use NSUndoManager):
            // inside retouch it drives stroke undo — enabled whenever a
            // session exists; empty-stack invocations no-op, since the
            // session's canUndo/canRedo changes aren't republished through
            // the model, deliberately, to keep cursor-move updates from
            // re-rendering the whole scene. Everywhere else it walks the
            // per-stack history of non-stroke edits (tone, crop, frame
            // selection).
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoMenuTitle) { model.undoEdit() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndoEdit)
                Button(model.redoMenuTitle) { model.redoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedoEdit)
            }
            // Replace the default (nonfunctional) help book entry with the
            // tutorial — someone reaching for Help wants the walkthrough,
            // not the product landing page.
            // Zoom lives in the system View menu (the .sidebar placement
            // anchors there even with no sidebar commands).
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Zoom to Fit") { model.viewport.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Hyperfocal Help") {
                    // The server 301s http → https; link the final URL.
                    NSWorkspace.shared.open(
                        URL(string: "https://ethannicholas.com/hyperfocal/tutorial.html")!)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // The set-and-forget pipeline switches live here (⌘,), out of the
        // sidebar's way; SettingsView documents each one inline.
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
