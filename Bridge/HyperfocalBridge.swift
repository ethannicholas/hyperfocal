// C-ABI bridge over AppCore for the Qt shell (cross-platform-plan Phase 2).
//
// Contract (documented for callers in QtShell/hyperfocal_bridge.h):
//  - Every hf_* call MUST be made on the process main thread. Qt's GUI
//    thread on macOS is that thread, and it pumps the CFRunLoop, so
//    DispatchQueue.main / MainActor work continues to drain under Qt's
//    event loop. Elsewhere nothing pumps it for us: the shell must call
//    hf_pump_main() periodically (a Qt timer) or main-queue work never
//    runs.
//  - The change callback fires on the main thread, coalesced per runloop
//    turn: many @Published mutations collapse into one callback, and the
//    model state is fully settled by the time it fires (objectWillChange
//    fires before values land, so delivery is deferred one turn).
//  - Pixel handoff is caller-allocated RGBA8888 (QImage::Format_RGBA8888)
//    tiles (hf_display_tile) of the model's own full-res preview CGImage —
//    the bridge holds no pixel cache; hf_display_epoch tells the pane when
//    its tiles went stale (tone edits never do — they are LUT-shader-only).
//
// Command surface is deliberately the walking skeleton's: open → fuse
// (progress) → display → tone → export. It grows feature-by-feature as
// the Qt shell mirrors the native app.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import AppCore
import HyperfocalKit

/// All bridge state, main-actor confined (the contract pins callers to the
/// main thread, so `assumeIsolated` below is sound).
@MainActor
private enum Bridge {
    static var model: AppModel?
    static var changeToken: AnyObject?    // AppModel.addChangeObserver
    static var changedCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    static var changedContext: UnsafeMutableRawPointer?
    static var dialogs: BridgeDialogs?
    /// Coalescing: objectWillChange can fire dozens of times per turn.
    static var notifyScheduled = false

    /// Identity of the last image each epoch saw — an epoch bumps only
    /// when its source returns a different CGImage, so tone drags
    /// (LUT-shader-only) and slider edits never invalidate pane tiles.
    static var lastDisplayImage: PlatformImage?
    static var displayEpoch: Int32 = 0
    static var lastInputImage: PlatformImage?
    static var inputEpoch: Int32 = 0
    /// Retouch display currency: identity is meaningless for the
    /// session's zero-copy images, so strokes bump the epoch through
    /// the dirty subscription and accumulate a union rect the pane
    /// reads via hf_display_dirty to invalidate only touched tiles.
    static var retouchDirty: CGRect?
    static var retouchChangeToken: AnyObject?
    static var lastSourceDisplay: PlatformImage?
    static var sourceDisplayEpoch: Int32 = 0

    static func retouchDisplayDirtied(_ rect: CGRect) {
        retouchDirty = retouchDirty?.union(rect) ?? rect
        displayEpoch &+= 1
        scheduleNotify()
    }

    static func currentSourceDisplayEpoch() -> Int32 {
        let image = model?.retouch?.sourceDisplay
        if image !== lastSourceDisplay {
            lastSourceDisplay = image
            sourceDisplayEpoch &+= 1
        }
        return sourceDisplayEpoch
    }

    static func currentDisplayEpoch() -> Int32 {
        // While retouching, the display serves per-call zero-copy
        // wrappers over the session's live bytes — identity can't drive
        // the epoch, so stroke dirt (retouchDisplayDirtied) and the
        // mode/depth toggles bump it explicitly instead.
        if model?.retouchMode == true { return displayEpoch }
        let image = displayImage()
        if image !== lastDisplayImage {
            lastDisplayImage = image
            displayEpoch &+= 1
        }
        return displayEpoch
    }

    static func currentInputEpoch() -> Int32 {
        let image = inputImage()
        if image !== lastInputImage {
            lastInputImage = image
            inputEpoch &+= 1
        }
        return inputEpoch
    }

    /// The input pane's image (mirrors the native pane): the cycling
    /// processing source mid-fuse, else the selected frame's preview
    /// (decoded raw, or warped into the fused canvas once alignment
    /// transforms exist). Toned by the pane like the output.
    static func inputImage() -> PlatformImage? {
        guard let model else { return nil }
        // The cycling processing source only takes over once it EXISTS —
        // until the first processed frame lands, the fuse keeps showing
        // the selected frame (the native showProcessingSource rule; the
        // preview must not flash away on Fuse).
        if model.phase.isRunning, let processing = model.processingSource {
            return processing
        }
        return model.inputPreview
    }

    static func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async {
            notifyScheduled = false
            changedCallback?(changedContext)
        }
    }

    /// The image the shell should display right now (mirrors the native
    /// output pane's priority): progressive while running, the depth map
    /// in depth mode, else the model's full-resolution untoned result
    /// preview — the very CGImage the native panes display, so the bridge
    /// keeps no pixel cache of its own. Data visualizations (progressive
    /// depth/gradient stages, the depth map) are served exactly as
    /// computed — tone applies to image pixels only, the same content
    /// rule the native pane follows.
    static func displayImage() -> PlatformImage? {
        guard let model else { return nil }
        if let preview = model.noiseFloorPreview { return preview }
        if model.phase.isRunning { return model.progressive }
        if model.outputMode == .depth { return model.depthPreview }
        return model.outputPreview
    }

    /// Whether the current display image is a data visualization (mid-fuse
    /// progressive, depth map) — the pane must not run its tone LUT over
    /// these, the same pixels-only rule the native pane follows.
    static func displayIsData() -> Bool {
        guard let model else { return false }
        if model.noiseFloorPreview != nil { return true }
        if model.phase.isRunning { return model.progressiveIsData }
        return model.outputMode == .depth
    }
}

/// DialogService over C callbacks: modal confirms and notices reach the
/// shell (which shows its own message boxes); file choosers stay empty —
/// the shell drives opens/saves explicitly through its own dialogs, so
/// the model never needs to ask for a path. Callbacks are invoked on the
/// main thread, synchronously, exactly like the AppKit implementation
/// (off-main model callers hop via DispatchQueue.main.sync first).
public typealias HFConfirmCallback = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    Int32, UnsafeMutableRawPointer?) -> Int32
public typealias HFNotifyCallback = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    Int32, UnsafeMutableRawPointer?) -> Void
public typealias HFGuideCallback = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

@MainActor
private final class BridgeDialogs: DialogService {
    var confirmCallback: HFConfirmCallback?
    var notifyCallback: HFNotifyCallback?
    var guideCallback: HFGuideCallback?
    var context: UnsafeMutableRawPointer?

    func confirm(message: String, informative: String,
                 confirmTitle: String, cancelTitle: String,
                 warning: Bool) -> Bool {
        guard let confirmCallback else { return false }
        return message.withCString { m in
            informative.withCString { i in
                confirmTitle.withCString { c in
                    cancelTitle.withCString { x in
                        confirmCallback(m, i, c, x, warning ? 1 : 0, context) != 0
                    }
                }
            }
        }
    }

    func notify(message: String, informative: String, warning: Bool) {
        guard let notifyCallback else { return }
        message.withCString { m in
            informative.withCString { i in
                notifyCallback(m, i, warning ? 1 : 0, context)
            }
        }
    }

    func openDownloadPage(message: String, informative: String, url: String) {
        guard let guideCallback else { return }
        message.withCString { m in
            informative.withCString { i in
                url.withCString { u in
                    guideCallback(m, i, u, context)
                }
            }
        }
    }

    // The shell chooses files itself; an unanswerable chooser reads as
    // "cancelled", which every call site treats as a safe no-op.
    func chooseProjectToOpen() -> URL? { nil }
    func chooseFrames(message: String) -> [URL] { [] }
    func chooseStackFolders(message: String) -> [URL] { [] }
    func chooseAccessGrant(for root: URL) -> URL? { nil }
    func chooseExportDirectory(message: String) -> URL? { nil }
    func chooseSaveProject(directory: URL?, suggestedName: String) -> URL? { nil }
    func chooseSaveAnimation(suggestedName: String) -> URL? { nil }
    func chooseSaveExport(suggestedName: String) -> URL? { nil }
}

/// Copy `string` into a caller-allocated, NUL-terminated UTF-8 buffer;
/// returns the byte count written (excluding the terminator).
private func fillUTF8(_ string: String,
                      _ buffer: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    guard let buffer, cap > 0 else { return 0 }
    let bytes = Array(string.utf8.prefix(Int(cap) - 1))
    buffer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { p in
        for (i, b) in bytes.enumerated() { p[i] = b }
        p[bytes.count] = 0
    }
    return Int32(bytes.count)
}

// MARK: - Exports

/// Drain the process main queue once (non-blocking). On Apple platforms
/// Qt's Cocoa event loop already pumps the CFRunLoop — which is what
/// drains DispatchQueue.main / MainActor work — so this is a no-op there.
/// Everywhere else the shell must call it periodically from its event
/// loop, or AppCore's main-queue hops (fuse completion, async decodes,
/// the coalesced change callback) never run.
@_cdecl("hf_pump_main")
public func hf_pump_main() {
    #if !canImport(Darwin)
    // A single non-blocking RunLoop pass: services the libdispatch main
    // queue (corelibs CF integration) and any main-thread Timers.
    _ = RunLoop.main.run(mode: .default, before: Date())
    #endif
}

@_cdecl("hf_init")
public func hf_init() -> Int32 {
    MainActor.assumeIsolated {
        guard Bridge.model == nil else { return 1 }
        let model = AppModel()
        Bridge.model = model
        Bridge.changeToken = model.addChangeObserver {
            MainActor.assumeIsolated { Bridge.scheduleNotify() }
        }
        return 1
    }
}

@_cdecl("hf_set_changed_callback")
public func hf_set_changed_callback(
    _ cb: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated {
        Bridge.changedCallback = cb
        Bridge.changedContext = ctx
    }
}

/// Install the shell's modal handlers (both NULL uninstalls, reverting to
/// "every interaction resolves as cancelled").
@_cdecl("hf_set_dialog_callbacks")
public func hf_set_dialog_callbacks(
    _ confirm: HFConfirmCallback?,
    _ notify: HFNotifyCallback?,
    _ ctx: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return }
        if confirm == nil && notify == nil {
            model.dialogs = nil
            Bridge.dialogs = nil
            return
        }
        let dialogs = Bridge.dialogs ?? BridgeDialogs()
        dialogs.confirmCallback = confirm
        dialogs.notifyCallback = notify
        dialogs.context = ctx
        Bridge.dialogs = dialogs
        model.dialogs = dialogs
    }
}

/// Install the shell's guided-download handler (a two-button alert whose
/// default button opens a URL). NULL clears just this handler without tearing
/// down the confirm/notify handlers. Registered separately from
/// `hf_set_dialog_callbacks` so its signature can grow independently.
@_cdecl("hf_set_guide_callback")
public func hf_set_guide_callback(
    _ guide: HFGuideCallback?,
    _ ctx: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return }
        if guide == nil {
            Bridge.dialogs?.guideCallback = nil
            return
        }
        let dialogs = Bridge.dialogs ?? BridgeDialogs()
        dialogs.guideCallback = guide
        dialogs.context = ctx
        Bridge.dialogs = dialogs
        model.dialogs = dialogs
    }
}

/// Load a stack: a folder of frames (or a single .hyperfocal project),
/// exactly like dropping it on the native app — drops ADD stacks to the
/// project (a second folder becomes a second stack); a project file
/// opens/replaces. Returns 0 if refused (e.g. a fuse is running).
@_cdecl("hf_load_stack")
public func hf_load_stack(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path, let string = String(validatingUTF8: path) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning else { return 0 }
        model.addStacks(urls: [URL(fileURLWithPath: string)])
        return 1
    }
}

@_cdecl("hf_can_fuse")
public func hf_can_fuse() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.canFuse == true ? 1 : 0 }
}

@_cdecl("hf_fuse")
public func hf_fuse() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.canFuse else { return 0 }
        model.fuse()
        return 1
    }
}

@_cdecl("hf_is_running")
public func hf_is_running() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        // A batch counts as running across its brief between-stack gaps,
        // so the shell's enabled/progress bindings hold for the whole run.
        return model.phase.isRunning || model.batchStatus != nil ? 1 : 0
    }
}

@_cdecl("hf_stage_fraction")
public func hf_stage_fraction() -> Double {
    MainActor.assumeIsolated { Bridge.model?.stageFraction ?? 0 }
}

/// UTF-8 stage/status text; returns the byte length written (excluding the
/// terminator). Empty when idle.
@_cdecl("hf_stage_text")
public func hf_stage_text(_ buffer: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.phase.isRunning || model.batchStatus != nil else { return 0 }
        // The batch prefix ("Stack i of N · ") rides along, as in the
        // native progress overlay; the ETA is its own label
        // (hf_stage_eta), matching native.
        return fillUTF8((model.batchStatus ?? "") + model.stageText,
                        buffer, cap)
    }
}

/// The discard-unsaved-work confirm ahead of New Project's folder
/// chooser (the native flow asks BEFORE the picker; passes trivially
/// when there is nothing to lose). 1 = proceed.
@_cdecl("hf_confirm_new_project")
public func hf_confirm_new_project() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning else { return 0 }
        return model.confirmDiscardingUnsavedWork(
            message: "Start a new project?",
            confirmTitle: "New Project") ? 1 : 0
    }
}

/// Start a new project from a frames folder, REPLACING the current
/// stacks — the native ingest path. hf_load_stack keeps its drop/add
/// semantics; this is the only replacing folder load. The caller runs
/// hf_confirm_new_project first.
@_cdecl("hf_new_project")
public func hf_new_project(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path, let string = String(validatingUTF8: path) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning else { return 0 }
        model.ingest(urls: [URL(fileURLWithPath: string)])
        return 1
    }
}

// MARK: Crop editing mode

/// The transactional crop-edit session, mirrored from the native
/// overlay: begin snapshots for cancel and initializes the rect to the
/// full canvas when none is set; accept folds "full canvas, no angle"
/// back to no-crop and records the undo edit; cancel restores the
/// snapshot. While the mode is active hf_display_crop reports none (the
/// panes must show the whole canvas under the handles) — the overlay
/// reads the live rect through hf_edit_crop instead.
@_cdecl("hf_crop_mode")
public func hf_crop_mode() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.cropMode == true ? 1 : 0 }
}

@_cdecl("hf_can_crop")
public func hf_can_crop() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.canCrop == true ? 1 : 0 }
}

@_cdecl("hf_begin_crop")
public func hf_begin_crop() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.canCrop, !model.cropMode else { return 0 }
        model.beginCrop()
        return 1
    }
}

@_cdecl("hf_accept_crop")
public func hf_accept_crop() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.cropMode else { return 0 }
        model.acceptCrop()
        return 1
    }
}

@_cdecl("hf_cancel_crop")
public func hf_cancel_crop() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.cropMode else { return 0 }
        model.cancelCrop()
        return 1
    }
}

/// The live editing rect/angle, un-gated by crop mode (raw
/// cropRect/cropAngle) — what the overlay renders, including after
/// model-side reshapes (aspect change, orientation swap). 1 when a
/// rect exists.
@_cdecl("hf_edit_crop")
public func hf_edit_crop(_ x: UnsafeMutablePointer<Double>?,
                         _ y: UnsafeMutablePointer<Double>?,
                         _ w: UnsafeMutablePointer<Double>?,
                         _ h: UnsafeMutablePointer<Double>?,
                         _ angle: UnsafeMutablePointer<Double>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else {
            return fillCrop(nil, 0, x, y, w, h, angle)
        }
        return fillCrop(model.cropRect, model.cropAngle, x, y, w, h, angle)
    }
}

/// Aspect lock by native label (Original/Custom/1:1/3:2/5:4/4:3/16:9);
/// setting it reshapes the rect area-preservingly, like the native
/// picker. hf_crop_aspect_ratio reports the active w/h constraint
/// (0 = freeform) the overlay enforces mid-resize; hf_crop_portrait +
/// hf_toggle_crop_orientation are the X-key orientation swap.
@_cdecl("hf_crop_aspect")
public func hf_crop_aspect(_ buffer: UnsafeMutablePointer<CChar>?,
                           _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.cropAspect.rawValue, buffer, cap)
    }
}

/// Sidebar section collapse — chrome state, but model-owned (persisted
/// with the other set-and-forget preferences) so both shells share it.
/// Names are AppModel.SidebarSection rawValues.
@_cdecl("hf_section_collapsed")
public func hf_section_collapsed(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let section = AppModel.SidebarSection(rawValue: string) else { return 0 }
        return model.isCollapsed(section) ? 1 : 0
    }
}

@_cdecl("hf_toggle_section")
public func hf_toggle_section(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let section = AppModel.SidebarSection(rawValue: string) else { return 0 }
        model.toggleSection(section)
        return 1
    }
}

@_cdecl("hf_set_crop_aspect")
public func hf_set_crop_aspect(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let aspect = AppModel.CropAspect(rawValue: string) else { return 0 }
        model.cropAspect = aspect
        return 1
    }
}

@_cdecl("hf_crop_aspect_ratio")
public func hf_crop_aspect_ratio() -> Double {
    MainActor.assumeIsolated {
        Bridge.model?.cropAspectRatio.map(Double.init) ?? 0
    }
}

@_cdecl("hf_crop_portrait")
public func hf_crop_portrait() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.cropPortrait == true ? 1 : 0 }
}

@_cdecl("hf_toggle_crop_orientation")
public func hf_toggle_crop_orientation() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.cropMode else { return 0 }
        model.toggleCropOrientation()
        return 1
    }
}

// MARK: Settings (the preferences window's pipeline toggles)

@MainActor
private func settingBinding(_ id: String, model: AppModel)
    -> (get: () -> Bool, set: (Bool) -> Void)? {
    switch id {
    case "order-by-capture":
        return ({ model.orderByCaptureTime }, { model.orderByCaptureTime = $0 })
    case "align":
        return ({ model.alignFrames }, { model.alignFrames = $0 })
    case "normalize-exposure":
        return ({ model.normalizeExposure }, { model.normalizeExposure = $0 })
    case "gpu":
        return ({ model.useGPU }, { model.useGPU = $0 })
    case "disk-cache":
        return ({ model.fusionDiskCache }, { model.fusionDiskCache = $0 })
    default:
        return nil
    }
}

/// Boolean settings by the native settings.* id leaves (order-by-
/// capture, align, normalize-exposure, gpu, disk-cache); persisted in
/// the shell's own suite via the model's didSet. Getter returns -1 for
/// unknown ids.
@_cdecl("hf_bool_setting")
public func hf_bool_setting(_ id: UnsafePointer<CChar>?) -> Int32 {
    guard let id, let string = String(validatingUTF8: id) else { return -1 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let binding = settingBinding(string, model: model) else { return -1 }
        return binding.get() ? 1 : 0
    }
}

@_cdecl("hf_set_bool_setting")
public func hf_set_bool_setting(_ id: UnsafePointer<CChar>?,
                                _ value: Int32) -> Int32 {
    guard let id, let string = String(validatingUTF8: id) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let binding = settingBinding(string, model: model) else { return 0 }
        binding.set(value != 0)
        return 1
    }
}

/// Whether a GPU engine exists (gates the Use GPU toggle, like the
/// native settings window's MetalEngine check).
@_cdecl("hf_gpu_available")
public func hf_gpu_available() -> Int32 {
    #if canImport(Metal)
    return MainActor.assumeIsolated { MetalEngine.shared != nil ? 1 : 0 }
    #else
    return 0
    #endif
}

// MARK: Retouch (the session lives in AppCore; the shell forwards
// events in full-image pixels and draws served tiles)

@_cdecl("hf_retouch_mode")
public func hf_retouch_mode() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.retouchMode == true ? 1 : 0 }
}

@_cdecl("hf_can_retouch")
public func hf_can_retouch() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return model.canStartRetouch ? 1 : 0
    }
}

/// Enter retouch (builds or resumes the session) and attach the dirty
/// subscription that keeps the pane's tiles current per stroke.
@_cdecl("hf_enter_retouch")
public func hf_enter_retouch() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.retouchMode else { return 0 }
        model.enterRetouch()
        guard let session = model.retouch else { return 0 }
        session.onDisplayDirty = { rect in
            MainActor.assumeIsolated { Bridge.retouchDisplayDirtied(rect) }
        }
        // The session's own published state (source loads, canPaint,
        // edits) must reach the shell's change callback — it is a
        // separate ObservableObject from the model.
        Bridge.retouchChangeToken = session.addChangeObserver {
            MainActor.assumeIsolated { Bridge.scheduleNotify() }
        }
        Bridge.retouchDisplayDirtied(
            CGRect(origin: .zero, size: session.nominalSize))
        return 1
    }
}

/// Done Retouching — commits the preview rebuild + depth merge in the
/// model; the session persists for "Continue Retouching".
@_cdecl("hf_exit_retouch")
public func hf_exit_retouch() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.retouchMode else { return 0 }
        model.exitRetouch()
        Bridge.retouchDirty = nil
        // Back to identity-driven epochs: force a mismatch so the pane
        // refetches the rebuilt output preview.
        Bridge.lastDisplayImage = nil
        Bridge.displayEpoch &+= 1
        return 1
    }
}

@_cdecl("hf_retouch_has_edits")
public func hf_retouch_has_edits() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.retouch?.hasEdits == true ? 1 : 0 }
}

/// Revert All — restores the pristine fusion, clears stroke undo.
@_cdecl("hf_revert_retouch")
public func hf_revert_retouch() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.retouch?.hasEdits == true else { return 0 }
        model.resetRetouch()
        return 1
    }
}

/// The union of image-space rects dirtied since the last call (strokes,
/// undo tiles, revert), cleared on read — pairs with the epoch bump so
/// the pane can evict only intersecting tiles. 0 when clean.
@_cdecl("hf_display_dirty")
public func hf_display_dirty(_ x: UnsafeMutablePointer<Int32>?,
                             _ y: UnsafeMutablePointer<Int32>?,
                             _ w: UnsafeMutablePointer<Int32>?,
                             _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let rect = Bridge.retouchDirty else { return 0 }
        Bridge.retouchDirty = nil
        let integral = rect.integral
        x?.pointee = Int32(integral.minX)
        y?.pointee = Int32(integral.minY)
        w?.pointee = Int32(integral.width)
        h?.pointee = Int32(integral.height)
        return 1
    }
}

// Strokes and hover, in full-image pixels (the shell maps pane→canvas
// through PaneItem and passes both segment endpoints so the stamp
// spacing math stays in the session).
@_cdecl("hf_retouch_stroke_begin")
public func hf_retouch_stroke_begin(_ x: Double, _ y: Double) {
    MainActor.assumeIsolated {
        Bridge.model?.retouch?.beginStroke(at: CGPoint(x: x, y: y))
    }
}

@_cdecl("hf_retouch_stroke_move")
public func hf_retouch_stroke_move(_ x0: Double, _ y0: Double,
                                   _ x1: Double, _ y1: Double) {
    MainActor.assumeIsolated {
        Bridge.model?.retouch?.continueStroke(from: CGPoint(x: x0, y: y0),
                                              to: CGPoint(x: x1, y: y1))
    }
}

@_cdecl("hf_retouch_stroke_end")
public func hf_retouch_stroke_end() {
    MainActor.assumeIsolated { Bridge.model?.retouch?.endStroke() }
}

@_cdecl("hf_retouch_hover")
public func hf_retouch_hover(_ x: Double, _ y: Double) {
    MainActor.assumeIsolated {
        Bridge.model?.retouch?.cursor = CGPoint(x: x, y: y)
    }
}

@_cdecl("hf_retouch_hover_clear")
public func hf_retouch_hover_clear() {
    MainActor.assumeIsolated { Bridge.model?.retouch?.cursor = nil }
}

/// Brush-circle state for the overlay: drawn only while a stroke would
/// actually paint (the native canPaint rule).
@_cdecl("hf_retouch_can_paint")
public func hf_retouch_can_paint() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.retouch?.canPaint == true ? 1 : 0 }
}

@_cdecl("hf_retouch_cursor")
public func hf_retouch_cursor(_ x: UnsafeMutablePointer<Double>?,
                              _ y: UnsafeMutablePointer<Double>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let cursor = Bridge.model?.retouch?.cursor else { return 0 }
        x?.pointee = cursor.x
        y?.pointee = cursor.y
        return 1
    }
}

@_cdecl("hf_retouch_brush_radius")
public func hf_retouch_brush_radius() -> Double {
    MainActor.assumeIsolated { Bridge.model?.retouch?.brushRadius ?? 0 }
}

/// Multiplicative brush resize (⌥-scroll and the [ ] keys).
@_cdecl("hf_retouch_adjust_brush")
public func hf_retouch_adjust_brush(_ factor: Double) {
    MainActor.assumeIsolated {
        Bridge.model?.retouch?.adjustBrushRadius(by: factor)
    }
}

// Sources: kind radio (0 frame, 1 pmax, 2 result), cycling, the
// sharpest-under-cursor auto-pick, and the PMax build's status/cancel.
@_cdecl("hf_retouch_source_kind")
public func hf_retouch_source_kind() -> Int32 {
    MainActor.assumeIsolated {
        switch Bridge.model?.retouch?.sourceKind {
        case .pmax: return 1
        case .dmap: return 2
        default: return 0
        }
    }
}

@_cdecl("hf_set_retouch_source_kind")
public func hf_set_retouch_source_kind(_ kind: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let session = Bridge.model?.retouch else { return 0 }
        session.selectKind(kind == 1 ? .pmax : kind == 2 ? .dmap : .frame)
        return 1
    }
}

@_cdecl("hf_retouch_cycle_source")
public func hf_retouch_cycle_source(_ delta: Int32) {
    MainActor.assumeIsolated {
        Bridge.model?.retouch?.cycleSource(by: Int(delta))
    }
}

@_cdecl("hf_retouch_auto_pick")
public func hf_retouch_auto_pick() {
    MainActor.assumeIsolated {
        guard let session = Bridge.model?.retouch,
              let cursor = session.cursor else { return }
        session.autoPickSource(at: cursor)
    }
}

@_cdecl("hf_retouch_toggle_pmax")
public func hf_retouch_toggle_pmax() {
    MainActor.assumeIsolated { Bridge.model?.retouch?.togglePMaxLayer() }
}

@_cdecl("hf_retouch_toggle_result")
public func hf_retouch_toggle_result() {
    MainActor.assumeIsolated { Bridge.model?.retouch?.toggleDMapLayer() }
}

@_cdecl("hf_retouch_source_name")
public func hf_retouch_source_name(_ buffer: UnsafeMutablePointer<CChar>?,
                                   _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let session = Bridge.model?.retouch else { return 0 }
        return fillUTF8(session.sourceName, buffer, cap)
    }
}

@_cdecl("hf_retouch_source_loading")
public func hf_retouch_source_loading() -> Int32 {
    MainActor.assumeIsolated {
        Bridge.model?.retouch?.sourceLoading == true ? 1 : 0
    }
}

@_cdecl("hf_retouch_source_error")
public func hf_retouch_source_error(_ buffer: UnsafeMutablePointer<CChar>?,
                                    _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let error = Bridge.model?.retouch?.sourceError else { return 0 }
        return fillUTF8(error, buffer, cap)
    }
}

@_cdecl("hf_retouch_source_status")
public func hf_retouch_source_status(_ buffer: UnsafeMutablePointer<CChar>?,
                                     _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let status = Bridge.model?.retouch?.sourceStatus else { return 0 }
        return fillUTF8(status, buffer, cap)
    }
}


// The retouch SOURCE pane's pixel surface, mirroring hf_input_*: the
// selected frame slice / PMax (low-res while forming) / eraser preview.
@_cdecl("hf_retouch_source_size")
public func hf_retouch_source_size(_ w: UnsafeMutablePointer<Int32>?,
                                   _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let image = Bridge.model?.retouch?.sourceDisplay else {
            w?.pointee = 0
            h?.pointee = 0
            return 0
        }
        w?.pointee = Int32(image.width)
        h?.pointee = Int32(image.height)
        return 1
    }
}

@_cdecl("hf_retouch_source_epoch")
public func hf_retouch_source_epoch() -> Int32 {
    MainActor.assumeIsolated { Bridge.currentSourceDisplayEpoch() }
}

@_cdecl("hf_retouch_source_tile")
public func hf_retouch_source_tile(_ level: Int32, _ x: Int32, _ y: Int32,
                                   _ w: Int32, _ h: Int32,
                                   _ rgba: UnsafeMutableRawPointer?,
                                   _ cap: Int) -> Int32 {
    MainActor.assumeIsolated {
        tileCopy(Bridge.model?.retouch?.sourceDisplay,
                 level, x, y, w, h, rgba, cap)
    }
}

/// The source pane's nominal canvas — the session canvas, so low-res
/// PMax forming previews map into the same viewport as the frames.
@_cdecl("hf_retouch_source_nominal")
public func hf_retouch_source_nominal(_ w: UnsafeMutablePointer<Int32>?,
                                      _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let session = Bridge.model?.retouch else { return 0 }
        w?.pointee = Int32(session.nominalSize.width)
        h?.pointee = Int32(session.nominalSize.height)
        return 1
    }
}

// MARK: Export flows

/// Persisted export options (the shell's own settings suite), addressed
/// by the native UI names — ExportFormat/ExportColorSpace raw values.
@_cdecl("hf_export_format")
public func hf_export_format(_ buffer: UnsafeMutablePointer<CChar>?,
                             _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.exportFormat.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_export_format")
public func hf_set_export_format(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let format = AppModel.ExportFormat(rawValue: string) else { return 0 }
        model.exportFormat = format
        return 1
    }
}

@_cdecl("hf_export_color_space")
public func hf_export_color_space(_ buffer: UnsafeMutablePointer<CChar>?,
                                  _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.exportColorSpace.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_export_color_space")
public func hf_set_export_color_space(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let space = AppModel.ExportColorSpace(rawValue: string) else { return 0 }
        model.exportColorSpace = space
        return 1
    }
}

@_cdecl("hf_animation_format")
public func hf_animation_format(_ buffer: UnsafeMutablePointer<CChar>?,
                                _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.animationFormat.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_animation_format")
public func hf_set_animation_format(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let format = AppModel.AnimationFormat(rawValue: string) else { return 0 }
        model.animationFormat = format
        return 1
    }
}

@_cdecl("hf_animation_path")
public func hf_animation_path(_ buffer: UnsafeMutablePointer<CChar>?,
                              _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.animationPath.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_animation_path")
public func hf_set_animation_path(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let path = AppModel.AnimationPath(rawValue: string) else { return 0 }
        model.animationPath = path
        return 1
    }
}

@_cdecl("hf_animation_duration")
public func hf_animation_duration(_ buffer: UnsafeMutablePointer<CChar>?,
                                  _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.animationDuration.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_animation_duration")
public func hf_set_animation_duration(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let duration = AppModel.AnimationDuration(rawValue: string) else { return 0 }
        model.animationDuration = duration
        return 1
    }
}

@_cdecl("hf_animation_strength")
public func hf_animation_strength(_ buffer: UnsafeMutablePointer<CChar>?,
                                  _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.animationStrength.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_animation_strength")
public func hf_set_animation_strength(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let strength = AppModel.AnimationStrength(rawValue: string) else { return 0 }
        model.animationStrength = strength
        return 1
    }
}

@_cdecl("hf_fused_stack_count")
public func hf_fused_stack_count() -> Int32 {
    MainActor.assumeIsolated { Int32(Bridge.model?.fusedStackCount ?? 0) }
}

@_cdecl("hf_can_export_aligned")
public func hf_can_export_aligned() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.canExportAligned == true ? 1 : 0 }
}

@_cdecl("hf_can_animate")
public func hf_can_animate() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.canAnimate == true ? 1 : 0 }
}

/// Write every fused stack to `dir` in the persisted format/color space.
/// Async — returns 1 when the export started; the per-stack summary
/// arrives through the notice dialog seam when it finishes, like the
/// native flow.
@_cdecl("hf_export_all")
public func hf_export_all(_ dir: UnsafePointer<CChar>?) -> Int32 {
    guard let dir, let string = String(validatingUTF8: dir) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model, model.fusedStackCount > 0,
              !model.phase.isRunning else { return 0 }
        let url = URL(fileURLWithPath: string)
        Task { @MainActor in
            let summary = await model.exportAllFused(to: url)
            model.dialogs?.notify(message: "Export All Fused",
                                  informative: summary, warning: false)
        }
        return 1
    }
}

/// Write the selected stack's aligned frames to `dir`. Async, summary
/// through the notice seam — mirrors hf_export_all.
@_cdecl("hf_export_aligned")
public func hf_export_aligned(_ dir: UnsafePointer<CChar>?) -> Int32 {
    guard let dir, let string = String(validatingUTF8: dir) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model, model.canExportAligned,
              !model.phase.isRunning else { return 0 }
        let url = URL(fileURLWithPath: string)
        Task { @MainActor in
            let summary = await model.exportAlignedFrames(to: url)
            model.dialogs?.notify(message: "Export Aligned Frames",
                                  informative: summary, warning: false)
        }
        return 1
    }
}

/// Render the rocking animation to `path` with the persisted settings
/// (tone baked, retouch and crop included). Async; failure surfaces
/// through the notice seam.
@_cdecl("hf_export_animation")
public func hf_export_animation(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path, let string = String(validatingUTF8: path) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model, model.canAnimate else { return 0 }
        let url = URL(fileURLWithPath: string)
        Task { @MainActor in
            if await !model.writeAnimation(to: url) {
                model.dialogs?.notify(message: "The animation could not be written.",
                                      informative: url.lastPathComponent,
                                      warning: true)
            }
        }
        return 1
    }
}

// MARK: Project lifecycle

/// Write the project to `path`, or to its existing file when NULL (the
/// native Save vs Save As split — the shell chooses the path with its
/// own dialog, like exports). 0 when NULL with no existing file, or on
/// write failure.
@_cdecl("hf_save_project")
public func hf_save_project(_ path: UnsafePointer<CChar>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        let url: URL
        if let path, let string = String(validatingUTF8: path) {
            url = URL(fileURLWithPath: string)
        } else if let existing = model.projectURL {
            url = existing
        } else {
            return 0
        }
        return model.writeProject(to: url) ? 1 : 0
    }
}

/// The open project's file path (window titles, Save reuse). Bytes; 0
/// when the project has never been saved.
@_cdecl("hf_project_path")
public func hf_project_path(_ buffer: UnsafeMutablePointer<CChar>?,
                            _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let url = Bridge.model?.projectURL else { return 0 }
        return fillUTF8(url.path, buffer, cap)
    }
}

/// Anything worth saving since the last save? (quit gate, dirty marker)
@_cdecl("hf_has_unsaved_work")
public func hf_has_unsaved_work() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.hasUnsavedWork == true ? 1 : 0 }
}

/// File > Close Stack — removes the selected stack (confirms through
/// the dialog seam when its fused work would be lost).
@_cdecl("hf_close_stack")
public func hf_close_stack() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning else { return 0 }
        model.closeSelectedStack()
        return 1
    }
}

/// File > Close Project — back to the empty state (confirms likewise).
@_cdecl("hf_close_project")
public func hf_close_project() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning else { return 0 }
        model.closeProject()
        return 1
    }
}

// MARK: Undo/redo of model edits (tone, crop, frame inclusion — the
// native ⌘Z family; retouch strokes keep their own undo, reached
// through the same entry points once retouch mode exists here)

/// Noise-floor drag bracket, mirroring the native slider's
/// onEditingChanged: begin switches the display to a live depth-map
/// preview that re-renders as hf_set_slider moves the floor (the pixel
/// epoch bumps per re-render — the pane follows for free); end drops
/// back to the normal display priority.
@_cdecl("hf_noise_floor_editing")
public func hf_noise_floor_editing(_ editing: Int32) {
    MainActor.assumeIsolated {
        if editing != 0 { Bridge.model?.beginNoiseFloorPreview() }
        else { Bridge.model?.endNoiseFloorPreview() }
    }
}

/// Tone drag bracket, mirroring the native sliders' onEditingChanged:
/// editing=1 snapshots a baseline, editing=0 records ONE undoable tone
/// edit for the whole drag (live hf_set_slider values in between are
/// not individually recorded). Without the bracket, tone changes made
/// through the bridge are silent to undo — call it around drags.
@_cdecl("hf_tone_editing")
public func hf_tone_editing(_ editing: Int32) {
    MainActor.assumeIsolated { Bridge.model?.toneEditing(editing != 0) }
}

@_cdecl("hf_can_undo")
public func hf_can_undo() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.canUndoEdit == true ? 1 : 0 }
}

@_cdecl("hf_can_redo")
public func hf_can_redo() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.canRedoEdit == true ? 1 : 0 }
}

@_cdecl("hf_undo")
public func hf_undo() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.canUndoEdit else { return 0 }
        model.undoEdit()
        return 1
    }
}

@_cdecl("hf_redo")
public func hf_redo() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.canRedoEdit else { return 0 }
        model.redoEdit()
        return 1
    }
}

/// Mode-scoped menu titles ("Undo Tone Change", …). Returns bytes.
@_cdecl("hf_undo_title")
public func hf_undo_title(_ buffer: UnsafeMutablePointer<CChar>?,
                          _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.undoMenuTitle, buffer, cap)
    }
}

@_cdecl("hf_redo_title")
public func hf_redo_title(_ buffer: UnsafeMutablePointer<CChar>?,
                          _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.redoMenuTitle, buffer, cap)
    }
}

/// Cancel the running fuse (or batch) — the progress overlay's Cancel
/// button. 0 when nothing is running.
@_cdecl("hf_cancel_fuse")
public func hf_cancel_fuse() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.phase.isRunning else { return 0 }
        model.cancelFusion()
        return 1
    }
}

/// Tone at its neutral defaults? (drives the Reset button's visibility,
/// like the native tone.reset)
@_cdecl("hf_tone_is_neutral")
public func hf_tone_is_neutral() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.tone.isNeutral == true ? 1 : 0 }
}

@_cdecl("hf_reset_tone")
public func hf_reset_tone() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        model.resetTone()
        return 1
    }
}

/// Fusion sliders at their defaults? (drives fusion.reset visibility)
@_cdecl("hf_fusion_is_default")
public func hf_fusion_is_default() -> Int32 {
    MainActor.assumeIsolated {
        Bridge.model?.fusionSettingsAreDefault == true ? 1 : 0
    }
}

@_cdecl("hf_reset_fusion")
public func hf_reset_fusion() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        model.resetFusionSettings()
        return 1
    }
}

/// The primary fusion algorithm as a persisted raw value ("dmap"/"pmax").
/// The shell shows "DMap"/"PMax"; the rawValue is what persists (never
/// localize it — see the DisplayNamed seam).
@_cdecl("hf_fusion_algorithm")
public func hf_fusion_algorithm(_ buffer: UnsafeMutablePointer<CChar>?,
                                _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        return fillUTF8(model.fusionMethod.rawValue, buffer, cap)
    }
}

@_cdecl("hf_set_fusion_algorithm")
public func hf_set_fusion_algorithm(_ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, let string = String(validatingUTF8: name) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let method = FusionMethod(rawValue: string) else { return 0 }
        model.fusionMethod = method
        return 1
    }
}

/// The running fuse's ETA text ("about 20 seconds left"); bytes, 0
/// when idle or unknown — the native progress.eta label's data.
@_cdecl("hf_stage_eta")
public func hf_stage_eta(_ buffer: UnsafeMutablePointer<CChar>?,
                         _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.phase.isRunning,
              let eta = model.stageETA else { return 0 }
        return fillUTF8(eta, buffer, cap)
    }
}

@_cdecl("hf_set_tone_exposure")
public func hf_set_tone_exposure(_ ev: Double) {
    MainActor.assumeIsolated { Bridge.model?.tone.exposure = ev }
}

@_cdecl("hf_tone_exposure")
public func hf_tone_exposure() -> Double {
    MainActor.assumeIsolated { Bridge.model?.tone.exposure ?? 0 }
}

/// Slider access by the accessibility-identifier vocabulary the UITest
/// command channel already speaks (UITestSupport "set-slider") — one id
/// namespace across the native journeys, the Qt shell, and any future
/// Qt journey harness.
@MainActor
private func sliderBinding(_ id: String, model: AppModel)
    -> (get: () -> Double, set: (Double) -> Void)? {
    switch id {
    case "fusion.slider.sharpness":
        return ({ model.sharpnessSigma }, { model.sharpnessSigma = $0 })
    case "fusion.slider.noise-floor":
        return ({ model.noiseFloor }, { model.noiseFloor = $0 })
    case "fusion.slider.median-radius":
        return ({ model.medianRadius }, { model.medianRadius = $0 })
    case "fusion.slider.blend-radius":
        return ({ model.blendRadius }, { model.blendRadius = $0 })
    case "fusion.slider.debloom-levels":
        // PMax coarse levels is an Int (0–8); round the slider's Double.
        return ({ Double(model.pmaxCoarseLevels) },
                { model.pmaxCoarseLevels = Int($0.rounded()) })
    case "fusion.slider.focus-threshold":
        return ({ model.pmaxFocusThreshold }, { model.pmaxFocusThreshold = $0 })
    case "tone.slider.exposure":
        return ({ model.tone.exposure }, { model.tone.exposure = $0 })
    case "tone.slider.contrast":
        return ({ model.tone.contrast }, { model.tone.contrast = $0 })
    case "tone.slider.highlights":
        return ({ model.tone.highlights }, { model.tone.highlights = $0 })
    case "tone.slider.shadows":
        return ({ model.tone.shadows }, { model.tone.shadows = $0 })
    case "tone.slider.whites":
        return ({ model.tone.whites }, { model.tone.whites = $0 })
    case "tone.slider.blacks":
        return ({ model.tone.blacks }, { model.tone.blacks = $0 })
    case "retouch.slider.brush-size":
        return ({ model.retouch?.brushRadius ?? 0 },
                { model.retouch?.brushRadius = $0 })
    case "retouch.slider.softness":
        return ({ model.retouch?.brushSoftness ?? 0 },
                { model.retouch?.brushSoftness = $0 })
    default:
        return nil
    }
}

@_cdecl("hf_set_slider")
public func hf_set_slider(_ id: UnsafePointer<CChar>?, _ value: Double) -> Int32 {
    guard let id, let string = String(validatingUTF8: id) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let binding = sliderBinding(string, model: model) else { return 0 }
        binding.set(value)
        return 1
    }
}

@_cdecl("hf_slider")
public func hf_slider(_ id: UnsafePointer<CChar>?) -> Double {
    guard let id, let string = String(validatingUTF8: id) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let binding = sliderBinding(string, model: model) else { return 0 }
        return binding.get()
    }
}

/// Output mode: 0 = Result, 1 = Depth (the depth map displays and exports
/// untoned — it is data, not pixels).
@_cdecl("hf_set_output_depth")
public func hf_set_output_depth(_ depth: Int32) {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return }
        let changed = (model.outputMode == .depth) != (depth != 0)
        model.outputMode = depth != 0 ? .depth : .result
        // In retouch the epoch is manual (identity can't see the
        // result↔depth swap of zero-copy wrappers).
        if changed, model.retouchMode {
            Bridge.retouchDisplayDirtied(
                CGRect(origin: .zero, size: model.retouch?.nominalSize ?? .zero))
        }
    }
}

@_cdecl("hf_output_depth")
public func hf_output_depth() -> Int32 {
    MainActor.assumeIsolated { Bridge.model?.outputMode == .depth ? 1 : 0 }
}

// MARK: Frame list (the selected stack's frames, native Stack-list order)

@_cdecl("hf_frame_count")
public func hf_frame_count() -> Int32 {
    MainActor.assumeIsolated { Int32(Bridge.model?.frames.count ?? 0) }
}

/// UTF-8 display name (last path component) of frame `index`; returns
/// bytes written.
@_cdecl("hf_frame_name")
public func hf_frame_name(_ index: Int32, _ buffer: UnsafeMutablePointer<CChar>?,
                          _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.frames.indices.contains(Int(index)) else { return 0 }
        return fillUTF8(model.frames[Int(index)].lastPathComponent, buffer, cap)
    }
}

@_cdecl("hf_frame_included")
public func hf_frame_included(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.frames.indices.contains(Int(index)) else { return 0 }
        return model.included.contains(model.frames[Int(index)]) ? 1 : 0
    }
}

/// Toggle a frame's checkbox through the model's edit-recording path
/// (undo-able in the native app; staleness tracking updates either way).
@_cdecl("hf_set_frame_included")
public func hf_set_frame_included(_ index: Int32, _ included: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.frames.indices.contains(Int(index)) else { return 0 }
        model.setIncluded(model.frames[Int(index)], to: included != 0)
        return 1
    }
}

/// The frame's issue summary (misfire/misalignment, flagged at fuse
/// time) — the native frame row's warning badge. Returns bytes; 0 when
/// the frame has no issue.
@_cdecl("hf_frame_issue")
public func hf_frame_issue(_ index: Int32, _ buffer: UnsafeMutablePointer<CChar>?,
                           _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.frames.indices.contains(Int(index)),
              let issue = model.frameIssues[model.frames[Int(index)]] else { return 0 }
        return fillUTF8(issue, buffer, cap)
    }
}

// MARK: Stack list (native Stack-tree order) + batch fuse

@_cdecl("hf_stack_count")
public func hf_stack_count() -> Int32 {
    MainActor.assumeIsolated { Int32(Bridge.model?.stacks.count ?? 0) }
}

@_cdecl("hf_stack_name")
public func hf_stack_name(_ index: Int32, _ buffer: UnsafeMutablePointer<CChar>?,
                          _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        return fillUTF8(model.stacks[Int(index)].name, buffer, cap)
    }
}

/// Index of the selected stack, -1 when none.
@_cdecl("hf_stack_selected")
public func hf_stack_selected() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              let index = model.stacks.firstIndex(where: {
                  $0.id == model.selectedStackID }) else { return -1 }
        return Int32(index)
    }
}

/// Select a stack — stashes the outgoing stack's state and installs the
/// target's, exactly like clicking its row. 0 if refused (running, or
/// already selected).
@_cdecl("hf_select_stack")
public func hf_select_stack(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning,
              model.stacks.indices.contains(Int(index)),
              model.stacks[Int(index)].id != model.selectedStackID else { return 0 }
        model.selectStack(model.stacks[Int(index)].id)
        return 1
    }
}

@_cdecl("hf_stack_enabled")
public func hf_stack_enabled(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        return model.stacks[Int(index)].enabled ? 1 : 0
    }
}

/// The "include this stack in Fuse Enabled Stacks" checkbox.
@_cdecl("hf_set_stack_enabled")
public func hf_set_stack_enabled(_ index: Int32, _ enabled: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        model.setStackEnabled(model.stacks[Int(index)].id, to: enabled != 0)
        return 1
    }
}

/// Status for the tree's glyphs: 0 unfused, 1 fusing, 2 fused, 3 failed
/// (hf_stack_failure carries the message).
@_cdecl("hf_stack_status")
public func hf_stack_status(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        switch model.status(of: model.stacks[Int(index)]) {
        case .unfused: return 0
        case .fusing: return 1
        case .fused: return 2
        case .failed: return 3
        }
    }
}

@_cdecl("hf_stack_failure")
public func hf_stack_failure(_ index: Int32, _ buffer: UnsafeMutablePointer<CChar>?,
                             _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)),
              case .failed(let message) =
                  model.status(of: model.stacks[Int(index)]) else { return 0 }
        return fillUTF8(message, buffer, cap)
    }
}

/// Frame count per stack row (the selected stack reads the live mirrors —
/// its Stack object is stale until stashed).
/// Load-time frame-order sanity warning (capture/name-order
/// disagreement) — the native stack row's badge. Set at scan time on
/// the Stack itself, so no selected-stack mirror is involved. Returns
/// bytes; 0 when none.
@_cdecl("hf_stack_order_warning")
public func hf_stack_order_warning(_ index: Int32,
                                   _ buffer: UnsafeMutablePointer<CChar>?,
                                   _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)),
              let warning = model.stacks[Int(index)].orderWarning else { return 0 }
        return fillUTF8(warning, buffer, cap)
    }
}

@_cdecl("hf_stack_frame_count")
public func hf_stack_frame_count(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        let stack = model.stacks[Int(index)]
        if stack.id == model.selectedStackID { return Int32(model.frames.count) }
        return Int32(stack.frames.count)
    }
}

/// Tree disclosure state, persisted in the model like native
/// (expandedStacks survives loads and stack churn).
@_cdecl("hf_stack_expanded")
public func hf_stack_expanded(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        return model.expandedStacks.contains(model.stacks[Int(index)].id) ? 1 : 0
    }
}

@_cdecl("hf_set_stack_expanded")
public func hf_set_stack_expanded(_ index: Int32, _ expanded: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(index)) else { return 0 }
        let id = model.stacks[Int(index)].id
        if expanded != 0 { model.expandedStacks.insert(id) }
        else { model.expandedStacks.remove(id) }
        return 1
    }
}

/// Any stack's frame rows (the tree's nested lists), through the same
/// model helpers the native tree uses — the selected stack reads the
/// live mirrors, and inclusion toggles are URL-global (undo-recorded)
/// regardless of which stack owns the frame.
@_cdecl("hf_stack_frame_name")
public func hf_stack_frame_name(_ stack: Int32, _ frame: Int32,
                                _ buffer: UnsafeMutablePointer<CChar>?,
                                _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(stack)) else { return 0 }
        let frames = model.listedFrames(of: model.stacks[Int(stack)])
        guard frames.indices.contains(Int(frame)) else { return 0 }
        return fillUTF8(frames[Int(frame)].lastPathComponent, buffer, cap)
    }
}

@_cdecl("hf_stack_frame_included")
public func hf_stack_frame_included(_ stack: Int32, _ frame: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(stack)) else { return 0 }
        let s = model.stacks[Int(stack)]
        let frames = model.listedFrames(of: s)
        guard frames.indices.contains(Int(frame)) else { return 0 }
        return model.isIncluded(frames[Int(frame)], in: s) ? 1 : 0
    }
}

@_cdecl("hf_set_stack_frame_included")
public func hf_set_stack_frame_included(_ stack: Int32, _ frame: Int32,
                                        _ included: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(stack)) else { return 0 }
        let frames = model.listedFrames(of: model.stacks[Int(stack)])
        guard frames.indices.contains(Int(frame)) else { return 0 }
        model.setIncluded(frames[Int(frame)], to: included != 0)
        return 1
    }
}

@_cdecl("hf_stack_frame_issue")
public func hf_stack_frame_issue(_ stack: Int32, _ frame: Int32,
                                 _ buffer: UnsafeMutablePointer<CChar>?,
                                 _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(stack)) else { return 0 }
        let s = model.stacks[Int(stack)]
        let frames = model.listedFrames(of: s)
        guard frames.indices.contains(Int(frame)),
              let issue = model.frameIssue(frames[Int(frame)], in: s) else { return 0 }
        return fillUTF8(issue, buffer, cap)
    }
}

/// How many enabled stacks need a (re)fuse — the native "Fuse N Stacks"
/// button's N.
@_cdecl("hf_pending_stack_count")
public func hf_pending_stack_count() -> Int32 {
    MainActor.assumeIsolated { Int32(Bridge.model?.pendingStackCount ?? 0) }
}

/// Serially fuse every enabled stack needing it, mirroring the native
/// batch: selection walks the queue, hf_stage_text carries the
/// "Stack i of N · " prefix, and hf_is_running holds until the batch
/// ends. 0 when refused (running) or nothing is pending.
@_cdecl("hf_fuse_enabled_stacks")
public func hf_fuse_enabled_stacks() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning,
              model.pendingStackCount > 0 else { return 0 }
        model.fuseEnabledStacks()
        return 1
    }
}

/// Size of the current display image (progressive mid-fuse, toned result
/// preview otherwise). 0 sizes = nothing to show.
@_cdecl("hf_display_size")
public func hf_display_size(_ w: UnsafeMutablePointer<Int32>?,
                            _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        if let model = Bridge.model, model.retouchMode,
           let session = model.retouch {
            w?.pointee = Int32(session.nominalSize.width)
            h?.pointee = Int32(session.nominalSize.height)
            return 1
        }
        guard let image = Bridge.displayImage() else {
            w?.pointee = 0
            h?.pointee = 0
            return 0
        }
        w?.pointee = Int32(image.width)
        h?.pointee = Int32(image.height)
        return 1
    }
}

/// Epoch of the display image's *pixels*: bumps only when displayImage()
/// returns a different image (progressive updates, fuse completion, the
/// Result/Depth toggle, retouch folds) — never for tone edits, which the
/// pane renders through its LUT shader without touching tiles.
@_cdecl("hf_display_epoch")
public func hf_display_epoch() -> Int32 {
    MainActor.assumeIsolated { Bridge.currentDisplayEpoch() }
}

/// Copy a tile of the current display image as RGBA8888 (row-major,
/// width*4 stride) — UNTONED; the pane applies tone via hf_tone_lut
/// unless hf_display_is_data. `level` is a power-of-two downsample
/// exponent (0 = native resolution); the level image measures
/// ceil(size / 2^level) and x/y/w/h are in level coordinates, the rect
/// inside the level image. Sampling is nearest, matching the engine's
/// preview discipline. Returns 1 on success; 0 on any bounds mismatch
/// (size changed mid-turn — re-query and retry on the next callback).
@_cdecl("hf_display_tile")
public func hf_display_tile(_ level: Int32, _ x: Int32, _ y: Int32,
                            _ w: Int32, _ h: Int32,
                            _ rgba: UnsafeMutableRawPointer?, _ cap: Int) -> Int32 {
    MainActor.assumeIsolated {
        // Retouch serves the session's live bytes through the scoped
        // zero-copy accessors — no pixel copy beyond the tile itself,
        // and the synchronous main-thread call keeps the wrap sound.
        if let model = Bridge.model, model.retouchMode,
           let session = model.retouch {
            if model.outputMode == .depth {
                return session.withDepthDisplayCGImage {
                    tileCopy($0, level, x, y, w, h, rgba, cap)
                }
            }
            return session.withDisplayCGImage {
                tileCopy($0, level, x, y, w, h, rgba, cap)
            }
        }
        return tileCopy(Bridge.displayImage(), level, x, y, w, h, rgba, cap)
    }
}

/// The shared tile-copy body behind hf_display_tile/hf_input_tile.
@MainActor
private func tileCopy(_ image: PlatformImage?, _ level: Int32, _ x: Int32, _ y: Int32,
                      _ w: Int32, _ h: Int32,
                      _ rgba: UnsafeMutableRawPointer?, _ cap: Int) -> Int32 {
    guard let rgba, let image, level >= 0, level < 16, x >= 0, y >= 0,
          w > 0, h > 0, cap >= Int(w) * Int(h) * 4 else { return 0 }
    let shift = Int(level)
    let levelW = (image.width + (1 << shift) - 1) >> shift
    let levelH = (image.height + (1 << shift) - 1) >> shift
    guard Int(x) + Int(w) <= levelW, Int(y) + Int(h) <= levelH else { return 0 }
    let srcX = Int(x) << shift, srcY = Int(y) << shift
    #if !canImport(CoreGraphics)
    // Nearest subsample straight out of the 8-bit buffer.
    let out = rgba.assumingMemoryBound(to: UInt8.self)
    image.rgba.withUnsafeBufferPointer { src in
        for row in 0..<Int(h) {
            let sy = min(srcY + (row << shift), image.height - 1)
            for col in 0..<Int(w) {
                let sx = min(srcX + (col << shift), image.width - 1)
                let si = (sy * image.width + sx) * 4
                let di = (row * Int(w) + col) * 4
                out[di] = src[si]
                out[di + 1] = src[si + 1]
                out[di + 2] = src[si + 2]
                out[di + 3] = 255
            }
        }
    }
    return 1
    #else
    let srcW = min(Int(w) << shift, image.width - srcX)
    let srcH = min(Int(h) << shift, image.height - srcY)
    guard let tile = image.cropping(
            to: CGRect(x: srcX, y: srcY, width: srcW, height: srcH)),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: rgba, width: Int(w), height: Int(h),
            bitsPerComponent: 8, bytesPerRow: Int(w) * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    ctx.interpolationQuality = .none
    ctx.draw(tile, in: CGRect(x: 0, y: 0, width: Int(w), height: Int(h)))
    return 1
    #endif
}

// MARK: Input pane (selected frame / processing source)

/// Select frame `index` in the stack list, like clicking its row — the
/// input pane follows (decoding is async; watch hf_input_epoch).
@_cdecl("hf_select_frame")
public func hf_select_frame(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.frames.indices.contains(Int(index)) else { return 0 }
        model.selection = [model.frames[Int(index)]]
        model.selectionChanged()
        return 1
    }
}

/// Select frame `frame` of stack `stack`, like clicking its nested tree
/// row — a frame in another stack switches stack selection with it
/// (selectionChanged's cross-stack rule; a no-op while running).
@_cdecl("hf_select_stack_frame")
public func hf_select_stack_frame(_ stack: Int32, _ frame: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model,
              model.stacks.indices.contains(Int(stack)) else { return 0 }
        let frames = model.listedFrames(of: model.stacks[Int(stack)])
        guard frames.indices.contains(Int(frame)) else { return 0 }
        model.selection = [frames[Int(frame)]]
        model.selectionChanged()
        return 1
    }
}

/// Index of the selected frame, -1 when none (or multi-selection).
@_cdecl("hf_selected_frame")
public func hf_selected_frame() -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, model.selection.count == 1,
              let url = model.selection.first,
              let index = model.frames.firstIndex(of: url) else { return -1 }
        return Int32(index)
    }
}

/// Input-pane image surface, mirroring hf_display_*: the cycling
/// processing source mid-fuse, else the selected frame's preview
/// (decoded raw, or warped into the fused canvas once alignment
/// transforms exist — the title says which). Toned by the pane exactly
/// like the output.
@_cdecl("hf_input_size")
public func hf_input_size(_ w: UnsafeMutablePointer<Int32>?,
                          _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let image = Bridge.inputImage() else {
            w?.pointee = 0
            h?.pointee = 0
            return 0
        }
        w?.pointee = Int32(image.width)
        h?.pointee = Int32(image.height)
        return 1
    }
}

@_cdecl("hf_input_epoch")
public func hf_input_epoch() -> Int32 {
    MainActor.assumeIsolated { Bridge.currentInputEpoch() }
}

@_cdecl("hf_input_tile")
public func hf_input_tile(_ level: Int32, _ x: Int32, _ y: Int32,
                          _ w: Int32, _ h: Int32,
                          _ rgba: UnsafeMutableRawPointer?, _ cap: Int) -> Int32 {
    MainActor.assumeIsolated {
        tileCopy(Bridge.inputImage(), level, x, y, w, h, rgba, cap)
    }
}

// MARK: Crop

/// Set (w/h > 0) or clear (otherwise) the crop rect, in result-canvas
/// pixels, plus its angle in degrees — the UITest set-crop command's
/// semantics (the native overlay's drag handles are the interactive
/// path; the Qt shell grows those with its crop editing later).
@_cdecl("hf_set_crop")
public func hf_set_crop(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                        _ angle: Double) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        if w > 0 && h > 0 {
            model.cropRect = CGRect(x: x, y: y, width: w, height: h)
            model.cropAngle = angle
        } else {
            model.cropRect = nil
            model.cropAngle = 0
        }
        return 1
    }
}

@MainActor
private func fillCrop(_ crop: CGRect?, _ cropAngle: Double,
                      _ x: UnsafeMutablePointer<Double>?,
                      _ y: UnsafeMutablePointer<Double>?,
                      _ w: UnsafeMutablePointer<Double>?,
                      _ h: UnsafeMutablePointer<Double>?,
                      _ angle: UnsafeMutablePointer<Double>?) -> Int32 {
    x?.pointee = crop.map { Double($0.minX) } ?? 0
    y?.pointee = crop.map { Double($0.minY) } ?? 0
    w?.pointee = crop.map { Double($0.width) } ?? 0
    h?.pointee = crop.map { Double($0.height) } ?? 0
    angle?.pointee = crop != nil ? cropAngle : 0
    return crop != nil ? 1 : 0
}

/// The crop the output pane should present right now (native
/// displayCrop): bounds-checked against the result, absent while a fuse
/// runs or none is set. The pane restricts its viewport to the rect —
/// the image rotated by -angle about the rect's center, clipped to the
/// rect — exactly the region hf_export writes. Pixels are untouched:
/// hf_display_epoch does not move on crop changes.
@_cdecl("hf_display_crop")
public func hf_display_crop(_ x: UnsafeMutablePointer<Double>?,
                            _ y: UnsafeMutablePointer<Double>?,
                            _ w: UnsafeMutablePointer<Double>?,
                            _ h: UnsafeMutablePointer<Double>?,
                            _ angle: UnsafeMutablePointer<Double>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else {
            return fillCrop(nil, 0, x, y, w, h, angle)
        }
        return fillCrop(model.displayCrop, model.displayCropAngle,
                        x, y, w, h, angle)
    }
}

/// The input pane's crop: the display crop, but only when the preview is
/// warped into the fused canvas (raw frame decodes aren't crop-mapped) —
/// the native inputCrop rule.
@_cdecl("hf_input_crop")
public func hf_input_crop(_ x: UnsafeMutablePointer<Double>?,
                          _ y: UnsafeMutablePointer<Double>?,
                          _ w: UnsafeMutablePointer<Double>?,
                          _ h: UnsafeMutablePointer<Double>?,
                          _ angle: UnsafeMutablePointer<Double>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning,
              model.inputPreviewAligned else {
            return fillCrop(nil, 0, x, y, w, h, angle)
        }
        return fillCrop(model.displayCrop, model.displayCropAngle,
                        x, y, w, h, angle)
    }
}

/// The input pane's title: selected frame name + " (aligned)" when the
/// preview is warped into the fused canvas. Empty while nothing shows.
@_cdecl("hf_input_title")
public func hf_input_title(_ buffer: UnsafeMutablePointer<CChar>?,
                           _ cap: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        // The native inputPaneTitle: the cycling processing-source label
        // mid-fuse, else the previewed frame's name (+ aligned marker).
        if model.phase.isRunning, model.processingSource != nil,
           let label = model.processingSourceLabel {
            return fillUTF8(label, buffer, cap)
        }
        guard let url = model.inputPreviewURL, model.inputPreview != nil else {
            return 0
        }
        let title = url.lastPathComponent
            + (model.inputPreviewAligned ? " (aligned)" : "")
        return fillUTF8(title, buffer, cap)
    }
}

/// 1 while the selected frame's decode is in flight — hf_input_tile still
/// serves the PREVIOUS image (and hf_input_title already names the new
/// frame), so anything comparing input pixels must wait for 0.
@_cdecl("hf_input_loading")
public func hf_input_loading() -> Int32 {
    MainActor.assumeIsolated {
        Bridge.model?.inputPreviewLoading == true ? 1 : 0
    }
}

/// The display's NOMINAL canvas size — the coordinate space the pane's
/// viewport lives in. Differs from hf_display_size only mid-fuse, when
/// progressive previews render smaller than the final canvas: mapping
/// tiles into nominal space keeps the user's pan/zoom stable across
/// the fuse (the native panes' sourceCanvas behavior).
@_cdecl("hf_display_nominal")
public func hf_display_nominal(_ w: UnsafeMutablePointer<Int32>?,
                               _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        if let model = Bridge.model, model.phase.isRunning,
           let nominal = model.progressiveNominalSize {
            w?.pointee = Int32(nominal.width)
            h?.pointee = Int32(nominal.height)
            return 1
        }
        return hf_display_size(w, h)
    }
}

/// The input pane's nominal canvas, likewise (processing-source nominal
/// mid-fuse, the input preview's own nominal otherwise).
@_cdecl("hf_input_nominal")
public func hf_input_nominal(_ w: UnsafeMutablePointer<Int32>?,
                             _ h: UnsafeMutablePointer<Int32>?) -> Int32 {
    MainActor.assumeIsolated {
        guard let model = Bridge.model else { return hf_input_size(w, h) }
        if model.phase.isRunning, model.processingSource != nil,
           let nominal = model.processingSourceNominalSize {
            w?.pointee = Int32(nominal.width)
            h?.pointee = Int32(nominal.height)
            return 1
        }
        if let nominal = model.inputNominalSize {
            w?.pointee = Int32(nominal.width)
            h?.pointee = Int32(nominal.height)
            return 1
        }
        return hf_input_size(w, h)
    }
}

/// 1 when the display image is a data visualization (aligner gradients,
/// forming depth map, the depth view) — the pane must skip its tone LUT.
@_cdecl("hf_display_is_data")
public func hf_display_is_data() -> Int32 {
    MainActor.assumeIsolated { Bridge.displayIsData() ? 1 : 0 }
}

/// Fill `out` with the current tone curve as `size` 16-bit grayscale
/// entries (the curve is per-channel-separable, so one shared ramp is the
/// whole cube — ToneCurve.colorCubeData builds the native color cube from
/// this same table). The pane samples it per channel in its LUT shader.
@_cdecl("hf_tone_lut")
public func hf_tone_lut(_ out: UnsafeMutablePointer<UInt16>?, _ size: Int32) -> Int32 {
    guard let out, size > 1 else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        let table = ToneCurve.lut(settings: model.tone, size: Int(size))
        for i in 0..<Int(size) {
            out[i] = UInt16((max(0, min(1, table[i])) * 65535).rounded())
        }
        return 1
    }
}

/// Export the current result through the model's export path (tone baked
/// for display-referred formats, crop applied). `format`, when non-NULL,
/// is an AppModel.ExportFormat raw value (e.g. "TIFF (16-bit)") applied
/// for THIS export only — the persisted preference (the shell's own
/// suite, HYPERFOCAL_SETTINGS_SUITE) is restored before returning, so an
/// explicit-format export never becomes a sticky settings change. NULL
/// exports with the model's current settings.
@_cdecl("hf_export")
public func hf_export(_ path: UnsafePointer<CChar>?,
                      _ format: UnsafePointer<CChar>?) -> Int32 {
    guard let path, let string = String(validatingUTF8: path) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model else { return 0 }
        var restore: AppModel.ExportFormat?
        if let format, let name = String(validatingUTF8: format) {
            guard let wanted = AppModel.ExportFormat(rawValue: name) else { return 0 }
            if wanted != model.exportFormat {
                restore = model.exportFormat
                model.exportFormat = wanted
            }
        }
        defer { if let restore { model.exportFormat = restore } }
        return model.writeExport(to: URL(fileURLWithPath: string)) ? 1 : 0
    }
}
