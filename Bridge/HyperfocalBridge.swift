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
//  - Pixel handoff is caller-allocated RGBA8888 (QImage::Format_RGBA8888),
//    sized by hf_display_size. The skeleton copies; the zero-copy tiled
//    currency comes with the real pane item.
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
    /// Coalescing: objectWillChange can fire dozens of times per turn.
    static var notifyScheduled = false

    /// Toned display preview cache: rebuilt when the result identity or
    /// tone changes. The full-res result stays in the model; the bridge
    /// serves a bounded preview (the pane's zoom-to-pixels comes later
    /// with tiling).
    static var previewBase: ImageBuffer?      // downsampled, untoned
    static var previewBaseSource: ObjectIdentifier?  // identity of model.result backing
    static var previewToned: CGImage?
    static var previewTone: ToneSettings?

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
    /// in depth mode, else the toned result preview. Data visualizations
    /// (progressive depth/gradient stages, the depth map) are served
    /// exactly as computed — tone applies to image pixels only, the same
    /// content rule the native pane follows.
    static func displayImage() -> CGImage? {
        guard let model else { return nil }
        if model.phase.isRunning { return model.progressive }
        if model.outputMode == .depth { return model.depthPreview }
        guard let result = model.result else { return nil }
        // Rebuild the untoned preview when the result changes.
        let downsampled: ImageBuffer
        if let cached = previewBase, previewBaseSource == ObjectIdentifier(model),
           cached.width > 0, previewResultEpoch == model.resultEpochForBridge {
            downsampled = cached
        } else {
            downsampled = result.downsampledNearest(maxSide: 1600)
            previewBase = downsampled
            previewBaseSource = ObjectIdentifier(model)
            previewResultEpoch = model.resultEpochForBridge
            previewToned = nil
        }
        // Re-tone only when the settings changed.
        if previewToned == nil || previewTone != model.tone {
            var toned = downsampled
            ToneCurve.apply(settings: model.tone, to: &toned)
            previewToned = try? ImageFile.cgImage8(from: toned)
            previewTone = model.tone
        }
        return previewToned
    }
    static var previewResultEpoch = 0
}

/// Cheap identity for "did the result change": AppModel has no epoch, so
/// the bridge tracks the buffer's dimensions + a sample; good enough for
/// the skeleton (a new fuse always changes at least the progressive→done
/// transition that triggers a refresh anyway).
extension AppModel {
    var resultEpochForBridge: Int {
        guard let result else { return 0 }
        return result.width &* 31 &+ result.height
    }
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

/// Load a stack: a folder of frames (or a single .hyperfocal project),
/// exactly like dropping it on the native app. Returns 0 if refused
/// (e.g. a fuse is running).
@_cdecl("hf_load_stack")
public func hf_load_stack(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path, let string = String(validatingUTF8: path) else { return 0 }
    return MainActor.assumeIsolated {
        guard let model = Bridge.model, !model.phase.isRunning else { return 0 }
        model.ingest(urls: [URL(fileURLWithPath: string)])
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
    MainActor.assumeIsolated { Bridge.model?.phase.isRunning == true ? 1 : 0 }
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
        guard let model = Bridge.model, model.phase.isRunning,
              let buffer, cap > 0 else { return 0 }
        let text = model.stageText + (model.stageETA.map { "  \($0)" } ?? "")
        let bytes = Array(text.utf8.prefix(Int(cap) - 1))
        buffer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        return Int32(bytes.count)
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
        guard let model = Bridge.model, let buffer, cap > 0,
              model.frames.indices.contains(Int(index)) else { return 0 }
        let name = model.frames[Int(index)].lastPathComponent
        let bytes = Array(name.utf8.prefix(Int(cap) - 1))
        buffer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        return Int32(bytes.count)
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

/// Copy the current display image as RGBA8888 (row-major, width*4 stride)
/// into a caller-allocated buffer of at least `cap` bytes. Returns 1 on
/// success. Call hf_display_size first; a mid-turn size change returns 0
/// (fetch again on the next change callback).
@_cdecl("hf_display_pixels")
public func hf_display_pixels(_ rgba: UnsafeMutableRawPointer?, _ cap: Int) -> Int32 {
    MainActor.assumeIsolated {
        guard let rgba, let image = Bridge.displayImage(),
              cap >= image.width * image.height * 4 else { return 0 }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: rgba, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0,
                                   width: image.width, height: image.height))
        return 1
    }
}

/// Export the current result through the model's export path (tone baked
/// for display-referred formats, crop applied). `format`, when non-NULL,
/// is an AppModel.ExportFormat raw value (e.g. "TIFF (16-bit)") applied
/// for THIS export only — the model's export settings live in the shared
/// persisted suite the native app reads, and a dev shell must not clobber
/// the user's preference as a side effect; the prior value is restored
/// before returning. NULL exports with the model's current settings.
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
