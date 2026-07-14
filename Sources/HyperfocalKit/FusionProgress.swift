import Foundation

/// Structured progress reporting for the fusion pipeline. `preview`, when
/// present, is a downsampled progressive render of the output as it accumulates
/// — suitable for live display, not for export.
public struct FusionProgress {

    public enum Stage: String {
        case registering = "Reading frames"
        case aligning = "Matching gradients"
        case slabs = "Fusing slabs"
        case depth = "Analyzing depth"
        case regularizing = "Regularizing depth map"
        case render = "Rendering"
        case finishing = "Finishing"
    }

    public let stage: Stage
    /// Completion within the current stage, 0...1.
    public let fraction: Double
    /// Output-side preview: the depth map forming (depth stage) or the render
    /// accumulating (render stage).
    public let preview: ImageBuffer?
    /// Full-resolution dimensions the (downsampled) preview represents, so a UI
    /// can display it in output coordinate space. 0 when there is no preview.
    public let previewFullWidth: Int
    public let previewFullHeight: Int
    /// Input-side preview: the frame currently being processed (-1 / nil when
    /// not applicable), so a UI can cycle the source pane during the wait.
    public let sourceFrameIndex: Int
    public let sourcePreview: ImageBuffer?
    public let sourceFullWidth: Int
    public let sourceFullHeight: Int

    public init(stage: Stage, fraction: Double, preview: ImageBuffer? = nil,
                previewFullWidth: Int = 0, previewFullHeight: Int = 0,
                sourceFrameIndex: Int = -1, sourcePreview: ImageBuffer? = nil,
                sourceFullWidth: Int = 0, sourceFullHeight: Int = 0) {
        self.stage = stage
        self.fraction = fraction
        self.preview = preview
        self.previewFullWidth = previewFullWidth
        self.previewFullHeight = previewFullHeight
        self.sourceFrameIndex = sourceFrameIndex
        self.sourcePreview = sourcePreview
        self.sourceFullWidth = sourceFullWidth
        self.sourceFullHeight = sourceFullHeight
    }
}

public typealias FusionProgressHandler = (FusionProgress) -> Void
