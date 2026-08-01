import HyperfocalKit

/// Static UI text shared verbatim between the macOS app and the Qt shell —
/// authored exactly once here, never as a literal at either call site. The
/// macOS app links `AppCore` directly and reads these constants; the Qt
/// shell reads the same values at runtime through the Bridge
/// (`hf_ui_string`, `Shell::uiString`), the same path already used for
/// dynamic AppCore strings like undo titles and stack warnings — this just
/// extends it to static chrome. Translation is unaffected: each value below
/// still resolves through `localizedString` against the one
/// `Localizable.xcstrings` catalog, exactly as a native literal would.
///
/// Before this file, the same English sentence was typed independently in
/// `App/Sources/*.swift` and `QtShell/*.qml` — two copies free to drift.
/// Add new shared strings here, not as new literals in either shell.
public enum UIStrings {

    // MARK: - App menu / project

    public static let aboutHyperfocal =
        localizedString("About Hyperfocal", comment: "Menu item: opens the about panel")
    public static let newProject =
        localizedString("New Project…", comment: "Menu item / empty-state button")
    public static let openProject =
        localizedString("Open Project…", comment: "Menu item")
    public static let addStackFolder =
        localizedString("Add Stack Folder…", comment: "Menu item")
    public static let closeStack =
        localizedString("Close Stack", comment: "Menu item")
    public static let closeProject =
        localizedString("Close Project", comment: "Menu item")
    public static let saveProject =
        localizedString("Save Project", comment: "Menu item")
    public static let saveProjectAs =
        localizedString("Save Project As…", comment: "Menu item")
    public static let openFolder =
        localizedString("Open Folder…", comment: "Empty-state button: point the app at a folder of frames")
    public static let hyperfocalHelp =
        localizedString("Hyperfocal Help", comment: "Menu item")
    public static let dropFolderHint =
        localizedString("Drop a folder of frames here, or:", comment: "Empty-state hint")

    // MARK: - Stack list

    public static let stackSingular =
        localizedString("Stack", comment: "Sidebar section title, one stack loaded")
    public static let stackPlural =
        localizedString("Stacks", comment: "Sidebar section title, more than one stack loaded")
    public static let includeAllFrames =
        localizedString("All", comment: "Button: include every frame in the current stack")
    public static let includeNoFrames =
        localizedString("None", comment: "Button: exclude every frame in the current stack")

    // MARK: - Fusion section

    public static let reset =
        localizedString("Reset", comment: "Button: restore a section's settings to their defaults")
    public static let fusionSectionTitle =
        localizedString("Fusion", comment: "Sidebar section title")
    public static let algorithmLabel =
        localizedString("Algorithm:", comment: "Label for the DMap/PMax picker")
    public static let algorithmDMapTip = localizedString(
        "Strengths: Accurate color. Cleaner handling of highlights. Depth map is necessary for certain features.\n\nWeaknesses: Can struggle with overlapping or translucent details.",
        comment: "Tooltip for the DMap algorithm choice")
    public static let algorithmPMaxTip = localizedString(
        "Strengths: Can do a better job with overlapping or translucent details.\n\nWeaknesses: Can alter colors and cause highlights to bloom.",
        comment: "Tooltip for the PMax algorithm choice")
    public static let sliderSharpnessLabel =
        localizedString("Sharpness σ", comment: "DMap slider label")
    public static let sliderSharpnessTip = localizedString(
        "Radius used to judge sharpness at each pixel. Larger is steadier on smooth surfaces; smaller resolves finer detail.",
        comment: "DMap sharpness slider tooltip")
    public static let sliderNoiseFloorLabel =
        localizedString("Noise floor", comment: "DMap slider label")
    public static let sliderNoiseFloorTip = localizedString(
        "Pixels below this sharpness are treated as featureless and take their depth from neighbors. Raise it until glow halos disappear; stop before real detail blurs.",
        comment: "DMap noise floor slider tooltip")
    public static let sliderMedianRadiusLabel =
        localizedString("Median radius", comment: "DMap slider label")
    public static let sliderMedianRadiusTip = localizedString(
        "Fixes small wrong-depth patches at subject edges by a majority vote over this radius. Raising this too high can cause thin details to become blurry.",
        comment: "DMap median radius slider tooltip")
    public static let sliderBlendRadiusLabel =
        localizedString("Blend radius", comment: "DMap slider label")
    public static let sliderBlendRadiusTip = localizedString(
        "How many neighboring frames blend at each pixel. Larger values are smoother but softer.",
        comment: "DMap blend radius slider tooltip")
    public static let sliderDebloomLevelsLabel =
        localizedString("Debloom levels", comment: "PMax slider label")
    public static let sliderDebloomLevelsTip = localizedString(
        "Suppresses highlight bloom by gating the coarsest pyramid levels. 0 turns it off; higher cuts more bloom.",
        comment: "PMax debloom levels slider tooltip")
    public static let sliderFocusThresholdLabel =
        localizedString("Focus threshold", comment: "PMax slider label")
    public static let sliderFocusThresholdTip = localizedString(
        "How sharp a frame must be to win over the bloomed one. Higher is stricter; too high rejects genuinely sharp detail.",
        comment: "PMax focus threshold slider tooltip")
    public static let fuseStack =
        localizedString("Fuse Stack", comment: "Button: fuse the selected stack")
    public static let fuseEnabledStacksTip = localizedString(
        "Fuses every enabled stack which needs it, one at a time.",
        comment: "Tooltip for the batch-fuse button")

    // MARK: - Tone section

    public static let toneSectionTitle =
        localizedString("Tone", comment: "Sidebar section title")
    public static let sliderExposureLabel =
        localizedString("Exposure", comment: "Tone slider label")
    public static let sliderExposureTip = localizedString(
        "Overall image brightness",
        comment: "Exposure slider tooltip")
    public static let sliderContrastLabel =
        localizedString("Contrast", comment: "Tone slider label")
    public static let sliderContrastTip = localizedString(
        "Overall image contrast",
        comment: "Contrast slider tooltip")
    public static let sliderHighlightsLabel =
        localizedString("Highlights", comment: "Tone slider label")
    public static let sliderHighlightsTip = localizedString(
        "Affects upper midtones and highlights without affecting pure white.",
        comment: "Highlights slider tooltip")
    public static let sliderShadowsLabel =
        localizedString("Shadows", comment: "Tone slider label")
    public static let sliderShadowsTip = localizedString(
        "Affects shadows without affecting pure black.",
        comment: "Shadows slider tooltip")
    public static let sliderWhitesLabel =
        localizedString("Whites", comment: "Tone slider label")
    public static let sliderWhitesTip = localizedString(
        "Adjusts the very top of the brightness range.",
        comment: "Whites slider tooltip")
    public static let sliderBlacksLabel =
        localizedString("Blacks", comment: "Tone slider label")
    public static let sliderBlacksTip = localizedString(
        "Adjusts the very bottom of the brightness range.",
        comment: "Blacks slider tooltip")

    // MARK: - Edit / crop / retouch section

    public static let editSectionTitle =
        localizedString("Edit", comment: "Sidebar section title")
    public static let cropHeader =
        localizedString("Crop", comment: "Crop controls header")
    public static let cropButton =
        localizedString("Crop…", comment: "Button: enter crop mode")
    public static let cropTip = localizedString(
        "Crop the result image",
        comment: "Crop button tooltip")
    public static let aspectRatioLabel =
        localizedString("Aspect Ratio", comment: "Crop aspect picker label")
    public static let swapCropOrientationTip =
        localizedString("Swap the crop between landscape and portrait (X).",
                         comment: "Tooltip for the crop orientation button")
    public static let accept =
        localizedString("Accept", comment: "Button: accept the current crop")
    public static let cancel =
        localizedString("Cancel", comment: "Button: cancel the current action")
    public static let startRetouching =
        localizedString("Start Retouching", comment: "Button")
    public static let continueRetouching =
        localizedString("Continue Retouching", comment: "Button")
    public static let retouchingTitle =
        localizedString("Retouching", comment: "Retouch controls header")
    public static let sliderBrushSizeLabel =
        localizedString("Brush size", comment: "Retouch slider label")
    public static let sliderBrushSizeTip = localizedString(
        "Brush radius in image pixels. Painting copies pixels from the aligned source frame into the output.",
        comment: "Brush size slider tooltip")
    public static let sliderSoftnessLabel =
        localizedString("Softness", comment: "Retouch slider label")
    public static let sliderSoftnessTip = localizedString(
        "Feathered fraction of the brush edge. 0% is hard-edged; 100% fades from the center.",
        comment: "Brush softness slider tooltip")
    public static let retouchFromLabel =
        localizedString("Retouch from", comment: "Picker label for the brush source")
    public static let retouchSourceImage =
        localizedString("Source Image", comment: "Retouch source option")
    public static let retouchPMaxResult =
        localizedString("PMax Result", comment: "Retouch source option")
    public static let retouchDMapResult =
        localizedString("DMap Result", comment: "Retouch source option")
    public static let retouchSourceTip = localizedString(
        "What the brush paints from. Source Image: any aligned frame (↑/↓ to pick, space for the sharpest). PMax Result: keeps both sides where depths overlap. DMap Result: the original fusion — use it to erase a stroke without undoing edits made after it.",
        comment: "Retouch source picker tooltip")
    public static let revertAll =
        localizedString("Revert All", comment: "Button: undo every retouch stroke")
    public static let doneRetouching =
        localizedString("Done Retouching", comment: "Button: exit retouch mode")

    // MARK: - Export section

    public static let exportSectionTitle =
        localizedString("Export", comment: "Sidebar section title")
    public static let exportResult =
        localizedString("Export Result…", comment: "Button")
    public static let exportDepthMap =
        localizedString("Export Depth Map…", comment: "Button, shown instead of Export Result… in depth mode")
    public static let exportAlignedFrames =
        localizedString("Export Aligned Frames…", comment: "Menu item / button")
    public static let exportRockingAnimation =
        localizedString("Export Rocking Animation…", comment: "Menu item / button")
    public static let exportRockingAnimationTip = localizedString(
        "A short video that rocks the result left and right for a parallax effect. Strength is set in the save dialog.",
        comment: "Rocking animation export tooltip")
    public static let exportAllFused =
        localizedString("Export All Fused…", comment: "Button, shown when more than one stack is fused")
    public static let exportAllFusedTip = localizedString(
        "Exports every fused stack, retouch edits included, to one folder named after the stacks.",
        comment: "Export All Fused tooltip")
    public static let includeStackTip = localizedString(
        "Include this stack in Fuse Enabled Stacks; frame checkboxes are unaffected.",
        comment: "Tooltip for a stack row's enable checkbox")
    public static let fusedStatusTip =
        localizedString("Fused — select to view, retouch, or export",
                         comment: "Tooltip for a stack row's fused status glyph")

    // MARK: - Export dialog fields

    public static let format =
        localizedString("Format:", comment: "Export dialog field label")
    public static let duration =
        localizedString("Duration:", comment: "Export dialog field label")
    public static let path =
        localizedString("Path:", comment: "Export dialog field label")
    public static let strength =
        localizedString("Strength:", comment: "Export dialog field label")
    public static let linearDisplayP3 =
        localizedString("Linear Display P3", comment: "Export color space option")
    public static let tiff16bit =
        localizedString("TIFF (16-bit)", comment: "Export format option")

    // MARK: - Settings

    public static let settingsOrderByCaptureTime =
        localizedString("Order frames by capture time", comment: "Settings toggle")
    public static let settingsAlignFrames =
        localizedString("Align frames", comment: "Settings toggle")
    public static let settingsEvenOutExposure =
        localizedString("Even out exposure", comment: "Settings toggle")
    public static let settingsUseGPU =
        localizedString("Use GPU", comment: "Settings toggle")
    public static let settingsCacheFrames =
        localizedString("Cache frames on disk while fusing", comment: "Settings toggle")

    // MARK: - Panes

    public static let outputTitle =
        localizedString("Output", comment: "Output pane title")
    public static let inputTitle =
        localizedString("Input", comment: "Input pane title, shown when no frame is selected")
    public static let selectFrameHint =
        localizedString("Select a frame in the Stack list", comment: "Input pane empty hint")
    public static let noOutputYet =
        localizedString("No output yet", comment: "Output pane empty hint")
    public static let loadingSource =
        localizedString("Loading source…", comment: "Retouch source pane loading hint")
    public static let pressFuseStackHint =
        localizedString("Press “Fuse Stack”", comment: "Output pane empty hint, shown when a fuse can run")
    public static let retouchedOutputHint =
        localizedString("Retouched Output — drag to paint from source",
                         comment: "Output pane hint, shown while retouching")

    // MARK: - Zoom bar

    public static let zoomLabel =
        localizedString("Zoom:", comment: "Zoom bar label")
    public static let zoomFit =
        localizedString("Fit", comment: "Zoom level: fit the image to the pane")

    /// Every value above, keyed by its Swift property name — what the Qt
    /// shell looks up through `hf_ui_string`/`Shell::uiString`. Keep in sync
    /// by construction: each entry mirrors the `static let` above it.
    public static let all: [String: String] = [
        "aboutHyperfocal": aboutHyperfocal,
        "newProject": newProject,
        "openProject": openProject,
        "addStackFolder": addStackFolder,
        "closeStack": closeStack,
        "closeProject": closeProject,
        "saveProject": saveProject,
        "saveProjectAs": saveProjectAs,
        "openFolder": openFolder,
        "hyperfocalHelp": hyperfocalHelp,
        "dropFolderHint": dropFolderHint,
        "stackSingular": stackSingular,
        "stackPlural": stackPlural,
        "includeAllFrames": includeAllFrames,
        "includeNoFrames": includeNoFrames,
        "reset": reset,
        "fusionSectionTitle": fusionSectionTitle,
        "algorithmLabel": algorithmLabel,
        "algorithmDMapTip": algorithmDMapTip,
        "algorithmPMaxTip": algorithmPMaxTip,
        "sliderSharpnessLabel": sliderSharpnessLabel,
        "sliderSharpnessTip": sliderSharpnessTip,
        "sliderNoiseFloorLabel": sliderNoiseFloorLabel,
        "sliderNoiseFloorTip": sliderNoiseFloorTip,
        "sliderMedianRadiusLabel": sliderMedianRadiusLabel,
        "sliderMedianRadiusTip": sliderMedianRadiusTip,
        "sliderBlendRadiusLabel": sliderBlendRadiusLabel,
        "sliderBlendRadiusTip": sliderBlendRadiusTip,
        "sliderDebloomLevelsLabel": sliderDebloomLevelsLabel,
        "sliderDebloomLevelsTip": sliderDebloomLevelsTip,
        "sliderFocusThresholdLabel": sliderFocusThresholdLabel,
        "sliderFocusThresholdTip": sliderFocusThresholdTip,
        "fuseStack": fuseStack,
        "fuseEnabledStacksTip": fuseEnabledStacksTip,
        "toneSectionTitle": toneSectionTitle,
        "sliderExposureLabel": sliderExposureLabel,
        "sliderExposureTip": sliderExposureTip,
        "sliderContrastLabel": sliderContrastLabel,
        "sliderContrastTip": sliderContrastTip,
        "sliderHighlightsLabel": sliderHighlightsLabel,
        "sliderHighlightsTip": sliderHighlightsTip,
        "sliderShadowsLabel": sliderShadowsLabel,
        "sliderShadowsTip": sliderShadowsTip,
        "sliderWhitesLabel": sliderWhitesLabel,
        "sliderWhitesTip": sliderWhitesTip,
        "sliderBlacksLabel": sliderBlacksLabel,
        "sliderBlacksTip": sliderBlacksTip,
        "editSectionTitle": editSectionTitle,
        "cropHeader": cropHeader,
        "cropButton": cropButton,
        "cropTip": cropTip,
        "aspectRatioLabel": aspectRatioLabel,
        "swapCropOrientationTip": swapCropOrientationTip,
        "accept": accept,
        "cancel": cancel,
        "startRetouching": startRetouching,
        "continueRetouching": continueRetouching,
        "retouchingTitle": retouchingTitle,
        "sliderBrushSizeLabel": sliderBrushSizeLabel,
        "sliderBrushSizeTip": sliderBrushSizeTip,
        "sliderSoftnessLabel": sliderSoftnessLabel,
        "sliderSoftnessTip": sliderSoftnessTip,
        "retouchFromLabel": retouchFromLabel,
        "retouchSourceImage": retouchSourceImage,
        "retouchPMaxResult": retouchPMaxResult,
        "retouchDMapResult": retouchDMapResult,
        "retouchSourceTip": retouchSourceTip,
        "revertAll": revertAll,
        "doneRetouching": doneRetouching,
        "exportSectionTitle": exportSectionTitle,
        "exportResult": exportResult,
        "exportDepthMap": exportDepthMap,
        "exportAlignedFrames": exportAlignedFrames,
        "exportRockingAnimation": exportRockingAnimation,
        "exportRockingAnimationTip": exportRockingAnimationTip,
        "exportAllFused": exportAllFused,
        "exportAllFusedTip": exportAllFusedTip,
        "includeStackTip": includeStackTip,
        "fusedStatusTip": fusedStatusTip,
        "format": format,
        "duration": duration,
        "path": path,
        "strength": strength,
        "linearDisplayP3": linearDisplayP3,
        "tiff16bit": tiff16bit,
        "settingsOrderByCaptureTime": settingsOrderByCaptureTime,
        "settingsAlignFrames": settingsAlignFrames,
        "settingsEvenOutExposure": settingsEvenOutExposure,
        "settingsUseGPU": settingsUseGPU,
        "settingsCacheFrames": settingsCacheFrames,
        "outputTitle": outputTitle,
        "inputTitle": inputTitle,
        "selectFrameHint": selectFrameHint,
        "noOutputYet": noOutputYet,
        "loadingSource": loadingSource,
        "pressFuseStackHint": pressFuseStackHint,
        "retouchedOutputHint": retouchedOutputHint,
        "zoomLabel": zoomLabel,
        "zoomFit": zoomFit,
    ]
}
