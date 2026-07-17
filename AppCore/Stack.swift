import AppKit
import Foundation
import HyperfocalKit

/// The fusion-relevant parameters a result was produced with, snapshotted at
/// fuse time (and saved in projects) so the Fuse buttons can tell whether
/// re-fusing would actually change anything. The GPU/CPU choice counts too:
/// in theory the engines match (90+ dB), but the toggle exists precisely for
/// when the GPU path misbehaves — flipping it must offer a re-fuse.
struct FuseSettings: Equatable, Codable {
    var align: Bool
    var useGPU: Bool
    var sharpnessSigma: Double
    var noiseFloor: Double
    var medianRadius: Double
    var blendRadius: Double
    var normalizeExposure: Bool

    init(align: Bool, useGPU: Bool, sharpnessSigma: Double, noiseFloor: Double,
         medianRadius: Double, blendRadius: Double, normalizeExposure: Bool) {
        self.align = align
        self.useGPU = useGPU
        self.sharpnessSigma = sharpnessSigma
        self.noiseFloor = noiseFloor
        self.medianRadius = medianRadius
        self.blendRadius = blendRadius
        self.normalizeExposure = normalizeExposure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        align = try c.decode(Bool.self, forKey: .align)
        // Snapshots written before the GPU choice was tracked default to GPU
        // (its default) rather than failing the whole project decode.
        useGPU = try c.decodeIfPresent(Bool.self, forKey: .useGPU) ?? true
        sharpnessSigma = try c.decode(Double.self, forKey: .sharpnessSigma)
        noiseFloor = try c.decode(Double.self, forKey: .noiseFloor)
        medianRadius = try c.decode(Double.self, forKey: .medianRadius)
        blendRadius = try c.decode(Double.self, forKey: .blendRadius)
        normalizeExposure = try c.decode(Bool.self, forKey: .normalizeExposure)
    }
}

/// One focus stack in a project: its frames, per-frame inclusion, and — once
/// fused — the complete output state including retouch edits.
///
/// Plain class, deliberately not observable: `AppModel` is the single source
/// of UI truth and mirrors the *selected* stack's state in its own published
/// properties (swapped in/out by `selectStack`); every mutation flows through
/// AppModel methods, which republish. For non-selected stacks these fields
/// hold the stashed state the tree rows read.
@MainActor
final class Stack: Identifiable {
    let id = UUID()
    var name: String
    var frames: [URL]
    var included: Set<URL>
    /// Stack checkbox: excluded from "Fuse Enabled Stacks" and shown dimmed.
    /// Does not touch the per-frame checkboxes.
    var enabled = true

    // Fusion output; `result == nil` means unfused.
    var result: ImageBuffer?
    var depthResult: ImageBuffer?
    var resultDepth: [Float] = []
    var resultSharpness: FrameSharpness?
    var resultGains: [SIMD3<Float>]?
    // Load-time frame-order sanity warning (capture/name order disagreement
    // or missing capture times) — see AppModel.orderWarning. Persisted with
    // the project so the badge survives reopen.
    var orderWarning: String?
    var fuseURLs: [URL] = []
    var fusedSettings: FuseSettings?
    /// Tone adjustments (preview + display-referred exports); per stack.
    var tone = ToneSettings()
    /// Non-destructive output crop in result-canvas pixels (nil = full
    /// canvas); applies to every export, the animation, and the panes.
    var cropRect: CGRect?
    /// Crop rotation in degrees, applied about the rect's center.
    var cropAngle: Double = 0
    var frameIssues: [URL: String] = [:]
    var outputPreview: CGImage?
    var depthPreview: CGImage?
    /// The last fuse of this stack failed with this message.
    var failureMessage: String?

    // Retouch state that outlives stack switches. The live RetouchSession does
    // not — its source caches run to gigabytes, so only the selected stack
    // keeps one; edits survive here as the working pixels.
    var savedWorking: ImageBuffer?
    var savedSourceIndex: Int?

    // Per-stack undo/redo of non-stroke edits (tone, crop, inclusion).
    // Session-only, like retouch stroke undo — not saved in projects.
    var undoHistory: [AppModel.ModelEdit] = []
    var redoHistory: [AppModel.ModelEdit] = []

    init(name: String, frames: [URL]) {
        self.name = name
        // Preserve the caller's order: frame ordering policy (capture time vs
        // filename, per the Loading setting) is decided at scan time, and
        // project restores must keep the order they were saved with.
        self.frames = frames
        self.included = Set(frames)
    }

    var isFused: Bool { result != nil }
}
