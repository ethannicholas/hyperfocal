import SwiftUI
import HyperfocalKit

/// Quit gate: a project holds retouch edits that can't be recomputed, and
/// writing it automatically at quit proved too slow — so termination asks
/// for confirmation when unsaved work exists.
///
/// Also disables window tabbing: tabs would show several scenes all bound
/// to the one shared AppModel — not a multi-project feature, just the same
/// project rendered twice. (Disabling tabbing removes the tab menu items at
/// the source; stripping them from the View menu instead races SwiftUI's
/// menu reinstalls — a flickering View menu during fuses.)
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
                    guard model.confirmTermination() else { return false }
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
        return MainActor.assumeIsolated {
            model?.confirmTermination() ?? true
        } ? .terminateNow : .terminateCancel
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Claim open-document events before AppKit's default handler runs.
        // That handler forwards to SwiftUI's internal app delegate, whose
        // external-event "activation" (AppWindowsController.
        // activateWindowForExternalEvent) CLOSES the one main window when
        // the event matches no scene — and the last-window-closed rule then
        // exits the app. Net effect: dropping a .hyperfocal on the window,
        // or double-clicking one in Finder while the app ran, silently quit
        // it (the quit gate never fires — the close is programmatic, not a
        // performClose; verified by breakpointing -[NSWindow close]).
        // Declining events per-scene instead is no better: WindowGroup +
        // handlesExternalEvents([]) parks double-click launches windowless,
        // and Window + handlesExternalEvents(["*"]) still closes the window.
        // Owning the event keeps SwiftUI out of it entirely; the URLs then
        // flow through the same queue application(_:open:) fed.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:with:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor,
                                           with reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject),
              list.numberOfItems > 0 else { return }
        var urls = [URL]()
        for index in 1...list.numberOfItems {
            if let data = list.atIndex(index)?
                .coerce(toDescriptorType: typeFileURL)?.data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        pendingOpenURLs += urls
        flushPendingOpens()
    }

    /// Unreachable while handleOpenDocuments owns the odoc event, but kept
    /// as the documented funnel: anything AppKit still routes here joins
    /// the same queue.
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
                    model.dialogs = MacDialogService(model: model)
                    appDelegate.model = model
                    appDelegate.installCloseGate()
                    UITestSupport.activate(model)
                }
        }
        .commands {
            // Hand-built About window (AboutWindow.swift): version, repo
            // link, the Adobe-required DNG attribution, and the Third-Party
            // Notices link — disclosures live behind About, not the Help
            // menu, on both shells.
            CommandGroup(replacing: .appInfo) {
                Button(UIStrings.aboutHyperfocal) { AboutWindow.show() }
            }
            CommandGroup(replacing: .newItem) {
                // Same action as the empty state's "Open Folder…" button,
                // deliberately named differently: from the File menu the
                // mental model is starting a project; from the empty window
                // it's pointing the app at a folder of frames.
                Button(UIStrings.newProject) { model.openFrames() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.phase.isRunning || model.savingProject)
                Button(UIStrings.openProject) { model.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.phase.isRunning || model.savingProject)
                Button(UIStrings.addStackFolder) { model.addStackFolderPanel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.phase.isRunning || model.savingProject)
                Button(UIStrings.closeStack) { model.closeSelectedStack() }
                    .disabled(model.phase.isRunning || model.savingProject
                              || model.selectedStackID == nil)
                Button(UIStrings.closeProject) { model.closeProject() }
                    .disabled(model.phase.isRunning || model.savingProject
                              || model.stacks.isEmpty)
                Divider()
                // Enabled only while there is something to save
                // (canSaveProject: content + unsaved changes + no write in
                // flight) — Save staying lit after a save made it unclear
                // whether anything had happened. `phase` only mirrors the
                // selected stack, so it gates running-ness, not content —
                // keying content on it wrongly disabled Save in multi-stack
                // projects whenever an unfused stack happened to be
                // selected. Save writes back to the project's file; a
                // never-saved project falls through to the Save As panel
                // (no ellipsis: the common case shows no dialog).
                Button(UIStrings.saveProject) { model.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSaveProject || model.phase.isRunning)
                Button(UIStrings.saveProjectAs) { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSaveProjectAs || model.phase.isRunning)
                // Label follows the output mode, like the export button and
                // the Qt shell's menu — in depth mode ⌘E exports the depth
                // map, and the menu should say so.
                Button(model.outputMode == .depth ? UIStrings.exportDepthMap
                                                  : UIStrings.exportResult) {
                    model.exportResult()
                }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.canExport)
                Button(UIStrings.exportAlignedFrames) { model.exportAlignedFramesPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportAligned)
                Button(UIStrings.exportRockingAnimation) { model.exportAnimation() }
                    .disabled(!model.canAnimate)
            }
            // Edit > Undo/Redo (we don't use NSUndoManager): one shared
            // timeline per stack — strokes, tone, crop, and frame
            // selection interleaved in the order they happened (strokes
            // ride the history as markers; see AppModel.ModelEdit.stroke).
            // Enablement and titles come off the model's @Published
            // histories, which change once per edit, not per cursor move.
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
                Button(UIStrings.hyperfocalHelp) {
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
