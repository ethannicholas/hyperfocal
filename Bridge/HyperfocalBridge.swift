// C-ABI bridge over AppCore for the Qt shell (cross-platform-plan Phase 2).
//
// Contract (documented for callers in QtShell/hyperfocal_bridge.h):
//  - Every hf_* call MUST be made on the process main thread. Qt's GUI
//    thread on macOS is that thread, and it pumps the CFRunLoop, so
//    DispatchQueue.main / MainActor work continues to drain under Qt's
//    event loop. (The Linux/Windows story — pumping the main queue from
//    Qt's loop — is a known open question this prototype defers.)
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
import CoreGraphics
import Combine
import HyperfocalKit

/// All bridge state, main-actor confined (the contract pins callers to the
/// main thread, so `assumeIsolated` below is sound).
@MainActor
private enum Bridge {
    static var model: AppModel?
    static var changeSink: AnyCancellable?
    static var changedCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    static var changedContext: UnsafeMutableRawPointer?
    static var dialogs: BridgeDialogs?
    /// Coalescing: objectWillChange can fire dozens of times per turn.
    static var notifyScheduled = false

    /// Identity of the last image each epoch saw — an epoch bumps only
    /// when its source returns a different CGImage, so tone drags
    /// (LUT-shader-only) and slider edits never invalidate pane tiles.
    static var lastDisplayImage: CGImage?
    static var displayEpoch: Int32 = 0
    static var lastInputImage: CGImage?
    static var inputEpoch: Int32 = 0

    static func currentDisplayEpoch() -> Int32 {
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
    static func inputImage() -> CGImage? {
        guard let model else { return nil }
        if model.phase.isRunning { return model.processingSource }
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
    static func displayImage() -> CGImage? {
        guard let model else { return nil }
        if model.phase.isRunning { return model.progressive }
        if model.outputMode == .depth { return model.depthPreview }
        return model.outputPreview
    }

    /// Whether the current display image is a data visualization (mid-fuse
    /// progressive, depth map) — the pane must not run its tone LUT over
    /// these, the same pixels-only rule the native pane follows.
    static func displayIsData() -> Bool {
        guard let model else { return false }
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

@MainActor
private final class BridgeDialogs: DialogService {
    var confirmCallback: HFConfirmCallback?
    var notifyCallback: HFNotifyCallback?
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

@_cdecl("hf_init")
public func hf_init() -> Int32 {
    MainActor.assumeIsolated {
        guard Bridge.model == nil else { return 1 }
        let model = AppModel()
        Bridge.model = model
        Bridge.changeSink = model.objectWillChange.sink { _ in
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
        // native toolbar.
        let text = (model.batchStatus ?? "") + model.stageText
            + (model.stageETA.map { "  \($0)" } ?? "")
        return fillUTF8(text, buffer, cap)
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
        Bridge.model?.outputMode = depth != 0 ? .depth : .result
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
        tileCopy(Bridge.displayImage(), level, x, y, w, h, rgba, cap)
    }
}

/// The shared tile-copy body behind hf_display_tile/hf_input_tile.
@MainActor
private func tileCopy(_ image: CGImage?, _ level: Int32, _ x: Int32, _ y: Int32,
                      _ w: Int32, _ h: Int32,
                      _ rgba: UnsafeMutableRawPointer?, _ cap: Int) -> Int32 {
    guard let rgba, let image, level >= 0, level < 16, x >= 0, y >= 0,
          w > 0, h > 0, cap >= Int(w) * Int(h) * 4 else { return 0 }
    let shift = Int(level)
    let levelW = (image.width + (1 << shift) - 1) >> shift
    let levelH = (image.height + (1 << shift) - 1) >> shift
    guard Int(x) + Int(w) <= levelW, Int(y) + Int(h) <= levelH else { return 0 }
    let srcX = Int(x) << shift, srcY = Int(y) << shift
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
        if model.phase.isRunning { return fillUTF8("Input", buffer, cap) }
        guard model.selection.count == 1, let url = model.selection.first,
              model.inputPreview != nil else { return 0 }
        let title = url.lastPathComponent
            + (model.inputPreviewAligned ? " (aligned)" : "")
        return fillUTF8(title, buffer, cap)
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
