import SwiftUI
import HyperfocalKit

/// App settings (⌘,): the set-and-forget pipeline switches. The per-stack
/// creative controls (sharpness σ, noise floor, median/blend radius) stay in
/// the sidebar. Loading settings apply to the next load; the rest are read
/// at fuse time, so a change applies to the next fuse.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Loading") {
                Toggle("Order frames by capture time", isOn: $model.orderByCaptureTime)
                    .accessibilityIdentifier("settings.order-by-capture")
                caption("Sorts each stack's frames by EXIF capture time when loading (filename order breaks when the camera's file counter rolls over mid-stack). Frames without timestamps fall back to filename order. Turn off to always order by filename.")
            }
            Section("Fusion") {
                Toggle("Align frames", isOn: $model.alignFrames)
                    .accessibilityIdentifier("settings.align")
                caption("Register every frame to its neighbor before fusing (focus breathing, drift, rotation). Turn off only for stacks that are already pixel-aligned, e.g. re-exports from another tool.")
                Toggle("Even out exposure", isOn: $model.normalizeExposure)
                    .accessibilityIdentifier("settings.normalize-exposure")
                caption("Measures each frame's overall brightness and corrects shot-to-shot exposure flicker (shutter or lighting variation) before blending, so it can't imprint brightness patches on the result.")
                Toggle("Slab deep stacks", isOn: $model.slabDeepStacks)
                    .accessibilityIdentifier("settings.slab")
                caption("For stacks of \(AppModel.slabThreshold)+ frames: fuse overlapping groups with pyramid (PMax) fusion first, then depth-map fuse the slabs. Helps where structures at different depths overlap, but retouching then sources from the slabs first, with the original frames after them.")
            }
            Section("Performance") {
                Toggle("Use GPU", isOn: $model.useGPU)
                    .accessibilityIdentifier("settings.gpu")
                    .disabled(MetalEngine.shared == nil)
                caption(MetalEngine.shared == nil
                        ? "No Metal device available — fusing runs on the CPU."
                        : "Fuse on the GPU (identical results, several times faster). Turn off to reduce memory pressure on low-RAM machines, free the GPU for other work, or rule out a driver issue.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
