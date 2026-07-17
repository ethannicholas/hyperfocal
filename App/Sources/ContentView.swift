import SwiftUI
import HyperfocalKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
            previewSide
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls = [URL]()
                for provider in providers {
                    if let url = try? await provider.loadURL() {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty {
                    await MainActor.run { model.addStacks(urls: urls) }
                }
            }
            return true
        }
    }

    // MARK: - Sidebar

    /// The frame list lives outside the Form: a List nested in a grouped Form
    /// doesn't get its own scrolling.
    private var sidebar: some View {
        VStack(spacing: 0) {
            stackPanel
            Divider()
            Form {
                fusionSection
                toneSection
                retouchSection
                exportSection
            }
            .formStyle(.grouped)
        }
    }

    private var stackPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                // Same real-button treatment as sectionHeader (accessibility
                // and automation); All/None stay siblings outside the button.
                Button {
                    model.toggleSection(.stack)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.isCollapsed(.stack)
                              ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.stacks.count > 1 ? "Stacks" : "Stack").font(.headline)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("section.stack")
                .accessibilityLabel("Stack section")
                .accessibilityValue(model.isCollapsed(.stack) ? "collapsed" : "expanded")
                if !model.frames.isEmpty {
                    Text("\(model.includedFrames.count) of \(model.frames.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .accessibilityIdentifier("stack.count")
                    if !model.isCollapsed(.stack) {
                        Button("All") { model.includeAll(true) }
                            .controlSize(.small)
                            .accessibilityIdentifier("stack.include-all")
                        Button("None") { model.includeAll(false) }
                            .controlSize(.small)
                            .accessibilityIdentifier("stack.include-none")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, model.isCollapsed(.stack) ? 10 : 0)

            if model.isCollapsed(.stack) {
                EmptyView()
            } else if model.stacks.isEmpty {
                VStack(spacing: 10) {
                    Text("Drop a folder of frames here, or:")
                        .foregroundStyle(.secondary)
                    Button("Open Folder…") { model.openFrames() }
                        .accessibilityIdentifier("stack.open-folder")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(.bottom, 10)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selection) {
                        // One stack keeps the familiar flat list; several show
                        // as folders with their own checkbox and status.
                        if model.stacks.count == 1 {
                            frameRows(of: model.stacks[0])
                        } else {
                            // Hand-rolled disclosure rather than
                            // DisclosureGroup: the group merges its label
                            // into a single accessibility element, fusing
                            // the row's checkbox and select button into one
                            // unusable control (identifiers concatenate) —
                            // opaque to VoiceOver and automation alike.
                            ForEach(model.stacks) { stack in
                                let expanded = model.expandedStacks.contains(stack.id)
                                HStack(spacing: 4) {
                                    Button {
                                        expansionBinding(stack).wrappedValue = !expanded
                                    } label: {
                                        Image(systemName: "chevron.right")
                                            .rotationEffect(.degrees(expanded ? 90 : 0))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("stack.row.\(stack.name).disclose")
                                    .accessibilityLabel(
                                        "\(expanded ? "Collapse" : "Expand") \(stack.name)")
                                    StackRow(stack: stack,
                                             isSelected: stack.id == model.selectedStackID,
                                             status: model.status(of: stack),
                                             setEnabled: { model.setStackEnabled(stack.id, to: $0) },
                                             select: { model.selectStack(stack.id) })
                                }
                                // Explicit scroll target: each ForEach element
                                // is two sibling views (header + frame rows) —
                                // scrollTo must land on the header.
                                .id(stack.id)
                                if expanded {
                                    frameRows(of: stack)
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 140, idealHeight: 280, maxHeight: 360)
                    .onChange(of: model.selection) { _, newValue in
                        model.selectionChanged()
                        if let url = newValue.first {
                            proxy.scrollTo(url)
                        }
                    }
                    .onAppear {
                        // A restored project arrives with its selection
                        // already set, so onChange never fires — without
                        // this, the list opens showing stack #1's frames
                        // while the selected stack sits offscreen (clicking
                        // a lookalike frame there switches stacks and reads
                        // as a broken project). The list appears at the
                        // top, so scroll ONLY when a later stack is
                        // selected (scrollTo has no scroll-until-visible
                        // mode — its nil anchor aligns to the top edge,
                        // which on a fresh load buried the selected
                        // stack's header above its first frame), and
                        // target the header so the stack arrives with its
                        // title and frames together. Deferred a tick: the
                        // rows are laid out in this same update.
                        DispatchQueue.main.async {
                            guard let stackID = model.selectedStackID,
                                  model.stacks.count > 1,
                                  stackID != model.stacks.first?.id else { return }
                            proxy.scrollTo(stackID, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func frameRows(of stack: Stack) -> some View {
        let enabled = stack.enabled
        ForEach(model.listedFrames(of: stack), id: \.self) { url in
            FrameRow(url: url,
                     included: model.isIncluded(url, in: stack),
                     issue: model.frameIssue(url, in: stack),
                     setIncluded: { model.setIncluded(url, to: $0) })
                .opacity(enabled ? 1 : 0.4)
                .disabled(!enabled)
        }
    }

    private func expansionBinding(_ stack: Stack) -> Binding<Bool> {
        Binding(get: { model.expandedStacks.contains(stack.id) },
                set: { expanded in
                    if expanded {
                        model.expandedStacks.insert(stack.id)
                    } else {
                        model.expandedStacks.remove(stack.id)
                    }
                })
    }

    /// Clickable section header: chevron + title are a real (plain-styled)
    /// button toggling the section's collapsed state (persisted across runs)
    /// — a button rather than a tap gesture so the header is accessible and
    /// automatable. `trailing` stays a sibling outside the button: nesting
    /// buttons inside a button label breaks hit-testing.
    private func sectionHeader<T: View>(
        _ title: String, _ section: AppModel.SidebarSection,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                model.toggleSection(section)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.isCollapsed(section)
                          ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Font pinned (matching the Stack panel's header): a
                    // collapsed section leaves its Section empty, and the
                    // grouped Form then restyles the *next* section's header
                    // as mid-group text — ambient styling can't be trusted
                    // here.
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("section.\(section.rawValue)")
            .accessibilityLabel("\(title) section")
            .accessibilityValue(model.isCollapsed(section) ? "collapsed" : "expanded")
            trailing()
        }
    }

    private func sectionHeader(_ title: String,
                               _ section: AppModel.SidebarSection) -> some View {
        sectionHeader(title, section) { EmptyView() }
    }

    private var fusionSection: some View {
        // Set-and-forget switches (alignment, GPU, exposure normalization)
        // live in Settings (⌘,); the sidebar keeps the per-stack creative
        // controls.
        Section {
            if !model.isCollapsed(.fusion) {
            LabeledSlider(
                label: "Sharpness σ", id: "fusion.slider.sharpness", value: $model.sharpnessSigma, range: 1...16,
                format: "%.1f px",
                help: "Radius of the local-contrast measurement that decides which frame is sharpest at each pixel. Larger values are steadier on smooth, low-texture surfaces; smaller values resolve finer depth detail.")
            LabeledSlider(
                label: "Noise floor", id: "fusion.slider.noise-floor", value: $model.noiseFloor, range: 0.01...1,
                format: "%.0f%%", displayScale: 100,
                help: "Fraction of the image's overall sharpness below which a pixel is treated as featureless and takes its depth from confident neighbors. Drag to preview the depth map this floor would produce: featureless regions inheriting smoothly from their surroundings is normal — raise the floor until glow halos standing off subjects disappear, and stop before real detail starts dissolving into its neighbors.",
                onEditingChanged: { editing in
                    if editing {
                        model.beginNoiseFloorPreview()
                    } else {
                        model.endNoiseFloorPreview()
                    }
                })
            LabeledSlider(
                label: "Median radius", id: "fusion.slider.median-radius", value: $model.medianRadius, range: 0...32,
                format: "%.0f px",
                help: "Size of the majority vote that removes isolated wrong-depth patches at edges where the background shows through a defocused subject. 0 disables it.")
            LabeledSlider(
                label: "Blend radius", id: "fusion.slider.blend-radius", value: $model.blendRadius,
                range: Double(DMapFusion.minBlendRadius)...4,
                format: "%.2f",
                help: "How many neighboring frames blend together at each pixel when rendering. Wider is smoother across focus transitions, but slightly softer.")

            Button {
                model.fuse()
            } label: {
                Label("Fuse Stack", systemImage: "square.3.layers.3d.down.forward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canFuse)
            .accessibilityIdentifier("fusion.fuse-stack")

            if model.stacks.filter(\.enabled).count > 1 {
                let pending = model.pendingStackCount
                Button {
                    model.fuseEnabledStacks()
                } label: {
                    Label(pending == 1 ? "Fuse 1 Stack" : "Fuse \(pending) Stacks",
                          systemImage: "square.stack.3d.forward.dottedline")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.phase.isRunning || pending == 0)
                .accessibilityIdentifier("fusion.fuse-enabled")
                .help("Fuses every enabled stack whose result is missing or out of date (frames or settings changed), one after another with the current settings; bad frames are excluded automatically.")
            }
            }
        } header: {
            sectionHeader("Fusion", .fusion) {
                if !model.fusionSettingsAreDefault {
                    Button("Reset") { model.resetFusionSettings() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("fusion.reset")
                }
            }
        }
    }

    private var toneSection: some View {
        Section {
            if !model.isCollapsed(.tone) {
            LabeledSlider(
                label: "Exposure", id: "tone.slider.exposure", value: $model.tone.exposure, range: -5...5,
                format: "%+.2f EV",
                help: "Overall brightness, in stops of linear light — the loupe for judging a fuse in deep shadow. Like every Tone control, it applies to the previews (including retouching) and bakes into TIFF/PNG/JPEG exports; Linear DNG is never affected.",
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: "Contrast", id: "tone.slider.contrast", value: $model.tone.contrast, range: -100...100,
                format: "%+.0f",
                help: "S-curve around the midtones: positive deepens shadows and brightens highlights, negative flattens.",
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: "Highlights", id: "tone.slider.highlights", value: $model.tone.highlights, range: -100...100,
                format: "%+.0f",
                help: "Brightens or recovers the upper midtones and highlights without moving pure white.",
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: "Shadows", id: "tone.slider.shadows", value: $model.tone.shadows, range: -100...100,
                format: "%+.0f",
                help: "Lifts or deepens the shadows without moving pure black — usually the fastest way to inspect a dark fuse.",
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: "Whites", id: "tone.slider.whites", value: $model.tone.whites, range: -100...100,
                format: "%+.0f",
                help: "Moves the white point itself: the very top of the range.",
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: "Blacks", id: "tone.slider.blacks", value: $model.tone.blacks, range: -100...100,
                format: "%+.0f",
                help: "Moves the black point itself: the very bottom of the range.",
                onEditingChanged: { model.toneEditing($0) })
            }
        } header: {
            sectionHeader("Tone", .tone) {
                if !model.tone.isNeutral {
                    Button("Reset") { model.resetTone() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("tone.reset")
                }
            }
        }
    }

    @ViewBuilder
    private var retouchSection: some View {
        // Always visible, like Export: a section that appears and vanishes
        // with the fuse state reads as broken; a disabled button explains
        // itself. Crop and Retouch are mutually exclusive modes; whichever
        // is active swaps its controls in.
        Section {
            if !model.isCollapsed(.retouch) {
                if model.cropMode {
                    CropControls(model: model)
                } else if model.retouchMode, let session = model.retouch {
                    RetouchControls(session: session,
                                    onDone: { model.exitRetouch() },
                                    onReset: { model.resetRetouch() })
                } else {
                    Button {
                        model.beginCrop()
                    } label: {
                        Label("Crop…", systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(!model.canCrop)
                    .accessibilityIdentifier("edit.crop")
                    .help("Non-destructive crop: applies to every export and the rocking animation, and is saved with the project.")
                    Button {
                        model.enterRetouch()
                    } label: {
                        Label(model.retouch?.hasEdits == true
                                ? "Continue Retouching"
                                : "Start Retouching",
                              systemImage: "paintbrush.pointed")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(model.phase != .done || model.result == nil || model.cropMode)
                    .accessibilityIdentifier("retouch.start")
                }
            }
        } header: {
            sectionHeader("Edit", .retouch)
        }
    }

    private var exportSection: some View {
        Section {
            if !model.isCollapsed(.export) {
            // Format and color space live in the export dialogs themselves
            // (ExportOptionsView in MacDialogService.swift) — the options sit
            // next to the decision they affect, Photoshop-style.
            Button {
                model.exportResult()
            } label: {
                Label(model.outputMode == .depth ? "Export Depth Map…" : "Export Result…",
                      systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canExport)
            .accessibilityIdentifier("export.result")

            Button {
                model.exportAnimation()
            } label: {
                Label("Export Rocking Animation…", systemImage: "video")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canAnimate)
            .accessibilityIdentifier("export.animate")
            .help("Writes a short video that rocks the result left and right using the depth map for parallax — depth becomes visible motion. Strength is chosen in the save dialog.")

            if model.fusedStackCount > 1 {
                Button {
                    model.exportAllFusedPanel()
                } label: {
                    Label("Export All Fused…", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.phase.isRunning)
                .accessibilityIdentifier("export.all")
                .help("Writes every fused stack (retouch edits included) to one folder, named after the stacks, in the format and color space chosen in the dialog.")
            }
            }
        } header: {
            sectionHeader("Export", .export)
        }
    }

    // MARK: - Preview side

    private var previewSide: some View {
        VStack(spacing: 0) {
            if model.retouchMode, let session = model.retouch {
                RetouchPreviewArea(session: session, tone: model.tone,
                                   outputMode: $model.outputMode)
            } else {
                fusionPreviewPanes
            }
            Divider()
            ZoomBar(viewport: model.viewport) { model.displayedImageSize }
        }
        .background(.black.opacity(0.9))
        .environmentObject(model.viewport)
    }

    private var fusionPreviewPanes: some View {
        HStack(spacing: 1) {
                PreviewPane(
                    title: inputPaneTitle,
                    paneID: "input.pane",
                    image: inputPaneImage,
                    nominalSize: (inputCrop?.size) ?? inputPaneNominal,
                    sourceOrigin: inputCrop?.origin ?? .zero,
                    sourceCanvas: inputPaneNominal,
                    sourceAngle: inputCrop != nil ? model.displayCropAngle : 0,
                    loading: model.inputPreviewLoading && !model.phase.isRunning,
                    emptyHint: model.inputPreviewError
                        ?? (model.frames.isEmpty
                            ? "Start a new project to begin"
                            : "Select a frame in the Stack list"),
                    tone: model.tone,
                    header: { EmptyView() }
                )
                PreviewPane(
                    title: "Output",
                    paneID: "output.pane",
                    image: outputImage,
                    nominalSize: model.displayCrop?.size ?? model.outputNominalSize,
                    sourceOrigin: model.displayCrop?.origin ?? .zero,
                    sourceCanvas: model.outputNominalSize,
                    sourceAngle: model.displayCropAngle,
                    loading: false,
                    emptyHint: model.canFuse ? "Press “Fuse Stack”" : "No output yet",
                    // Depth maps and the noise-floor preview are data
                    // visualizations, not image content — leave them alone.
                    tone: (model.outputMode == .depth
                           || model.noiseFloorPreview != nil) ? ToneSettings() : model.tone,
                    eventOverlay: model.cropMode ? AnyView(CropOverlay(
                        viewport: model.viewport,
                        canvas: model.outputNominalSize ?? .zero,
                        aspect: model.cropAspectRatio,
                        rect: $model.cropRect,
                        angle: $model.cropAngle)) : nil,
                    header: {
                        Picker("", selection: $model.outputMode) {
                            ForEach(AppModel.OutputMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 130)
                        .disabled(model.depthPreview == nil)
                        .accessibilityIdentifier("output.mode")
                    }
                )
                .overlay(alignment: .bottom) {
                    if model.phase.isRunning {
                        VStack(spacing: 6) {
                            ProgressView(value: model.stageFraction)
                                .accessibilityIdentifier("progress.bar")
                            HStack {
                                Text("\(model.batchStatus ?? "")\(model.stageText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("progress.stage")
                                if let eta = model.stageETA {
                                    Text(eta)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .accessibilityIdentifier("progress.eta")
                                }
                                Spacer()
                                Button("Cancel") { model.cancelFusion() }
                                    .controlSize(.small)
                                    .accessibilityIdentifier("progress.cancel")
                            }
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                    }
                }
            }
    }

    private var outputImage: CGImage? {
        if let preview = model.noiseFloorPreview { return preview }
        if model.phase.isRunning { return model.progressive }
        return model.outputMode == .depth ? model.depthPreview : model.outputPreview
    }

    // During a run, the input pane cycles through frames as they're processed.
    private var showProcessingSource: Bool {
        model.phase.isRunning && model.processingSource != nil
    }

    private var inputPaneTitle: String {
        if showProcessingSource, let label = model.processingSourceLabel { return label }
        guard let url = model.inputPreviewURL else { return "Input" }
        return url.lastPathComponent + (model.inputPreviewAligned ? " (aligned)" : "")
    }

    private var inputPaneImage: CGImage? {
        showProcessingSource ? model.processingSource : model.inputPreview
    }

    private var inputPaneNominal: CGSize? {
        showProcessingSource ? model.processingSourceNominalSize : model.inputNominalSize
    }

    /// The crop applies to the input pane only when it shows an *aligned*
    /// preview (same canvas as the result); raw-file previews have their
    /// own dimensions.
    private var inputCrop: CGRect? {
        guard !showProcessingSource, model.inputPreviewAligned else { return nil }
        return model.displayCrop
    }

}

// MARK: - Retouch preview area

/// Owns observation of the retouch session (panes must live-update with
/// strokes, source cycling, and the hover cursor).
struct RetouchPreviewArea: View {
    @ObservedObject var session: RetouchSession
    var tone = ToneSettings()
    /// The Result/Depth toggle stays available while retouching: strokes
    /// co-paint the depth plane, so depth artifacts (which the rocking
    /// animation turns into motion) are fixed with the depth view live.
    @Binding var outputMode: AppModel.OutputMode

    var body: some View {
        HStack(spacing: 1) {
            PreviewPane(
                title: "Source: \(session.sourceName)  ↑/↓ cycle · space picks sharpest",
                image: session.sourceDisplay,
                nominalSize: session.nominalSize,
                loading: session.sourceLoading,
                emptyHint: session.sourceError ?? "Loading source…",
                loadingStatus: session.sourceStatus,
                brushCursor: brushCursor,
                tone: tone,
                header: { EmptyView() }
            )
            PreviewPane(
                title: outputMode == .depth
                    ? "Retouched Depth — drag to paint from source"
                    : "Retouched Output — drag to paint from source",
                image: nil,
                nominalSize: session.nominalSize,
                loading: false,
                emptyHint: "",
                brushCursor: brushCursor,
                eventOverlay: AnyView(
                    RetouchOverlay(viewport: viewport,
                                   imageSize: session.nominalSize,
                                   session: session)),
                canvas: AnyView(RetouchCanvas(session: session, viewport: viewport,
                                              tone: tone,
                                              showDepth: outputMode == .depth)),
                header: {
                    Picker("", selection: $outputMode) {
                        ForEach(AppModel.OutputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 130)
                    .accessibilityIdentifier("output.mode")
                }
            )
        }
    }

    /// Only offered when a stroke would actually paint — no circle over a
    /// still-loading source, and none for the rest of a drag that started
    /// before the source arrived.
    private var brushCursor: (point: CGPoint, radius: CGFloat)? {
        guard session.canPaint else { return nil }
        return session.cursor.map { ($0, CGFloat(session.brushRadius)) }
    }

    @EnvironmentObject var viewport: ViewportState
}

// MARK: - Retouch controls

struct RetouchControls: View {
    @ObservedObject var session: RetouchSession
    let onDone: () -> Void
    let onReset: () -> Void

    var body: some View {
        LabeledSlider(
            label: "Brush size", id: "retouch.slider.brush-size", value: $session.brushRadius,
            range: RetouchSession.brushRadiusRange,
            format: "%.0f px",
            help: "Brush radius in image pixels. Painting copies pixels from the aligned source frame into the output.")
        LabeledSlider(
            label: "Softness", id: "retouch.slider.softness", value: $session.brushSoftness, range: 0...1,
            format: "%.0f%%", displayScale: 100,
            help: "Feathered fraction of the brush edge. 0% is hard-edged; 100% fades from the center.")
        Picker("Retouch from", selection: Binding(
            get: { session.sourceKind },
            set: { session.selectKind($0) })) {
            Text("Source Image").tag(RetouchSession.SourceKind.frame)
            Text("PMax Result").tag(RetouchSession.SourceKind.pmax)
            Text("Original Result (erase)").tag(RetouchSession.SourceKind.result)
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("retouch.source-kind")
        .help("What the brush paints from. Source Image: any aligned frame (↑/↓ to pick, space for the sharpest under the brush). PMax Result: a pyramid fusion of the whole stack — where structures at different depths overlap, the depth map has to pick one side, and this layer keeps both; built on first use, then cached. Original Result: the untouched fusion — an eraser that restores it exactly where a stroke overreached, without undoing everything since.")
        if session.sourceKind == .pmax && session.sourceLoading {
            Button("Cancel PMax Build") { session.cancelPMaxBuild() }
                .controlSize(.small)
                .accessibilityIdentifier("retouch.pmax-cancel")
                .help("Stop building the PMax layer and go back to the previous brush source. Selecting PMax Result again restarts the build.")
        }
        HStack {
            Spacer()
            Button("Revert All", role: .destructive) { onReset() }
                .disabled(!session.hasEdits)
                .accessibilityIdentifier("retouch.revert-all")
        }
        Text("↑/↓ cycle source frames · space picks the sharpest frame for the brush region · p PMax result · r eraser · ⌥-scroll or [ ] resize the brush · scroll/pinch to navigate")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button {
            onDone()
        } label: {
            Label("Done Retouching", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("retouch.done")
    }
}

// MARK: - Zoom bar

/// Observes the viewport directly — the label must update live as gestures and
/// menu picks change the zoom.
struct ZoomBar: View {
    @ObservedObject var viewport: ViewportState
    let imageSize: () -> CGSize

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Text("Zoom:")
                .foregroundStyle(.secondary)
            Menu {
                Button("Fit") { viewport.reset() }
                ForEach(ViewportState.fixedLevels, id: \.self) { level in
                    Button(ViewportState.percentLabel(level)) {
                        viewport.mode = .scale(level)
                    }
                }
            } label: {
                Text(label)
                    .monospacedDigit()
                    .frame(width: 60)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("zoom.menu")
            .accessibilityLabel("Zoom level")
            .accessibilityValue(label)

            Button {
                viewport.zoom(by: 1 / 1.5, imageSize: imageSize())
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityIdentifier("zoom.out")
            .accessibilityLabel("Zoom out")
            Button {
                viewport.zoom(by: 1.5, imageSize: imageSize())
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityIdentifier("zoom.in")
            .accessibilityLabel("Zoom in")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var label: String {
        switch viewport.mode {
        case .fit: return "Fit"
        case .scale(let s): return ViewportState.percentLabel(s)
        }
    }
}

// MARK: - Frame row

/// A stack's folder row in the tree: enable checkbox, name, status glyph,
/// frame count. Clicking selects the stack (only one stack is selected at a
/// time; the checkbox *enables* it for the queue, which is independent).
struct StackRow: View {
    let stack: Stack
    let isSelected: Bool
    let status: AppModel.StackStatus
    let setEnabled: (Bool) -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // labelsHidden keeps the title out of the layout but in the
            // accessibility tree — the checkbox is otherwise nameless.
            Toggle("Include \(stack.name) in Fuse Enabled Stacks",
                   isOn: Binding(get: { stack.enabled }, set: { setEnabled($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Include this stack in Fuse Enabled Stacks. Doesn't change its per-frame checkboxes.")
                .accessibilityIdentifier("stack.row.\(stack.name).enabled")
            if let warning = stack.orderWarning {
                // Frame-order sanity: a shuffled or interleaved load fuses to
                // garbage silently, and an undated stack quietly falls back
                // to filename order. Outside the row button so it stays its
                // own accessibility element (hover shows the full text).
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .help(warning)
                    .accessibilityIdentifier("stack.row.\(stack.name).order-warning")
                    .accessibilityLabel(warning)
            }
            // Selection is a real (plain) button, not a tap gesture, so rows
            // are accessible and automatable.
            Button {
                select()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(stack.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(stack.enabled
                                         ? (isSelected ? Color.accentColor : Color.primary)
                                         : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusGlyph
                    Text("\(stack.frames.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stack.row.\(stack.name)")
            .accessibilityLabel("Stack \(stack.name)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        // DisclosureGroup merges its label into one accessibility element,
        // fusing the checkbox and select button into a single mushy control
        // (identifiers concatenate; neither action is reachable). Contain
        // keeps them as separate, individually-actionable children.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .unfused:
            EmptyView()
        case .fusing:
            ProgressView()
                .controlSize(.small)
        case .fused:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .help("Fused — select to view, retouch, or export")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
                .help(message)
        }
    }
}

struct FrameRow: View {
    let url: URL
    let included: Bool
    /// Why the last fuse flagged this frame, if it did (misfire, misalignment).
    let issue: String?
    let setIncluded: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Include \(url.lastPathComponent)",
                   isOn: Binding(get: { included }, set: { setIncluded($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityIdentifier("frame.row.\(url.lastPathComponent).included")
            Text(url.lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(included ? .primary : .secondary)
                .accessibilityIdentifier("frame.row.\(url.lastPathComponent)")
            if let issue {
                Spacer(minLength: 2)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .help(issue)
            }
        }
    }
}

// MARK: - Synced zoomable pane

struct PreviewPane<Header: View>: View {
    static var headerHeight: CGFloat { 30 }

    let title: String
    /// Accessibility namespace for the pane; names the title ("<id>.title")
    /// and empty-state hint ("<id>.hint") so tests can read pane state.
    var paneID: String? = nil
    let image: CGImage?
    /// Coordinate-space size in full-resolution pixels. The bitmap may be lower
    /// resolution (progressive previews); it is stretched to this space so both
    /// panes always share one coordinate system.
    let nominalSize: CGSize?
    /// Crop display: the displayed region's origin within the bitmap's full
    /// canvas, and that canvas's size (nil = nominalSize). nominalSize is
    /// then the crop's size — the panes' shared coordinate space is the
    /// cropped canvas.
    var sourceOrigin: CGPoint = .zero
    var sourceCanvas: CGSize? = nil
    /// Crop rotation in degrees (drawn as -angle about the crop's center).
    var sourceAngle: Double = 0
    let loading: Bool
    let emptyHint: String
    /// Shown under the spinner during long loads (e.g. PMax layer build).
    var loadingStatus: String? = nil
    /// Brush circle to draw at an image-space point (retouch mode).
    var brushCursor: (point: CGPoint, radius: CGFloat)? = nil
    /// Tone adjustments applied to the displayed image via a Core Image
    /// layer filter (neutral = untouched). Self-drawing canvases tone
    /// themselves.
    var tone = ToneSettings()
    /// Custom event layer; defaults to plain pan/zoom.
    var eventOverlay: AnyView? = nil
    /// Self-drawing content (retouch canvas); replaces the Image when set.
    var canvas: AnyView? = nil
    @ViewBuilder let header: () -> Header

    @EnvironmentObject var viewport: ViewportState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(paneID.map { "\($0).title" } ?? "")
                Spacer()
                header()
            }
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight)
            .background(.bar)

            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let canvas {
                        canvas
                    } else if let image, let nominal = nominalSize {
                        let scale = viewport.effectiveScale(imageSize: nominal, viewSize: geo.size)
                        let canvas = sourceCanvas ?? nominal
                        let bitmapScale = canvas.width * scale / CGFloat(max(image.width, 1))
                        if !tone.isNeutral {
                            // Toned: an AppKit view drawing the visible
                            // region at native backing resolution, toned by
                            // a Core Image color cube on its layer — the
                            // identical machinery to RetouchCanvas. SwiftUI's
                            // shader pipeline cannot render this pane: at
                            // image extent its rasterization is texture-
                            // capped (45 MP panes went ~5× soft, and >65k
                            // points overflows its half-float coordinates —
                            // images vanished panned to the far edge); at
                            // pane extent (Canvas/drawingGroup) it rasterizes
                            // at 1× points — 2× soft on Retina — and
                            // drawingGroup ignores Image.interpolation.
                            TonedImagePane(image: image, nominalSize: nominal,
                                           sourceOrigin: sourceOrigin,
                                           sourceCanvas: sourceCanvas ?? nominal,
                                           sourceAngle: sourceAngle,
                                           viewport: viewport, tone: tone)
                                .allowsHitTesting(false)
                        } else {
                            // Inner container = the crop region's view rect;
                            // the (possibly rotated) bitmap is clipped to it,
                            // so nothing outside the crop ever renders.
                            ZStack {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .interpolation(bitmapScale >= 2 ? .none : .high)
                                    .frame(width: canvas.width * scale,
                                           height: canvas.height * scale)
                                    .rotationEffect(.degrees(-sourceAngle), anchor: UnitPoint(
                                        x: (sourceOrigin.x + nominal.width / 2) / max(canvas.width, 1),
                                        y: (sourceOrigin.y + nominal.height / 2) / max(canvas.height, 1)))
                                    .position(x: (canvas.width / 2 - sourceOrigin.x) * scale,
                                              y: (canvas.height / 2 - sourceOrigin.y) * scale)
                            }
                            .frame(width: nominal.width * scale,
                                   height: nominal.height * scale)
                            .clipped()
                            .position(x: geo.size.width / 2 - viewport.offset.width * scale,
                                      y: geo.size.height / 2 - viewport.offset.height * scale)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            // .clipped() clips drawing but NOT hit testing —
                            // when zoomed, the image's frame extends far past
                            // the pane and would swallow clicks meant for the
                            // zoom bar. All interaction happens on
                            // PanZoomOverlay anyway.
                            .allowsHitTesting(false)
                        }
                    } else if loading {
                        VStack(spacing: 8) {
                            ProgressView()
                            if let loadingStatus {
                                Text(loadingStatus)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(emptyHint)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(paneID.map { "\($0).hint" } ?? "")
                    }
                    if let brush = brushCursor, let nominal = nominalSize {
                        let scale = viewport.effectiveScale(imageSize: nominal, viewSize: geo.size)
                        let diameter = max(2, brush.radius * 2 * scale)
                        ZStack {
                            Circle().stroke(.black.opacity(0.6), lineWidth: 3)
                            Circle().stroke(.white.opacity(0.9), lineWidth: 1.5)
                        }
                        .frame(width: diameter, height: diameter)
                        .position(
                            x: geo.size.width / 2
                                + (brush.point.x - nominal.width / 2 - viewport.offset.width) * scale,
                            y: geo.size.height / 2
                                + (brush.point.y - nominal.height / 2 - viewport.offset.height) * scale)
                        .allowsHitTesting(false)
                    }
                }
                .clipped()
                .overlay {
                    // Feedback while a *replacement* image decodes (big frames
                    // take seconds) or a long build shows its forming preview
                    // (PMax layer); the empty-state spinner handles image==nil.
                    if loading && image != nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            if let loadingStatus {
                                Text(loadingStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    eventOverlay
                        ?? AnyView(PanZoomOverlay(viewport: viewport,
                                                  imageSize: nominalSize ?? .zero))
                )
            }
        }
    }

}

/// Shared tone application for pane NSViews: the curve as a Core Image
/// color cube on the backing layer. ToneCurve.colorCubeData is the single
/// source, so every toned pane renders exactly what the export CPU path
/// bakes.
class ToneFilteredPaneView: NSView {
    private var appliedTone = ToneSettings()

    func applyTone(_ tone: ToneSettings) {
        guard tone != appliedTone else { return }
        appliedTone = tone
        wantsLayer = true
        if tone.isNeutral {
            layer?.filters = nil
        } else if let filter = CIFilter(name: "CIColorCubeWithColorSpace") {
            let dimension = 64
            filter.setValue(dimension, forKey: "inputCubeDimension")
            filter.setValue(ToneCurve.colorCubeData(settings: tone,
                                                    dimension: dimension),
                            forKey: "inputCubeData")
            filter.setValue(CGColorSpace(name: CGColorSpace.displayP3),
                            forKey: "inputColorSpace")
            layer?.filters = [filter]
        }
    }

    override var isFlipped: Bool { true }
}

/// The toned pane's image layer: the visible region CG-drawn at native
/// backing resolution, toned by the layer filter — the identical machinery
/// to RetouchCanvas, so toned panes stay pixel- and color-comparable with
/// it. Mirrors the plain Image branch's position math exactly: a toned pane
/// must not shift by a pixel relative to a neutral one.
final class TonedImagePaneNSView: ToneFilteredPaneView {
    /// Observed directly via Combine — SwiftUI's updateNSView isn't reliably
    /// re-invoked when only the viewport changes (same as RetouchCanvas).
    var viewport: ViewportState? {
        didSet {
            guard viewport !== oldValue else { return }
            viewportSubscription = viewport?.objectWillChange.sink { [weak self] _ in
                // objectWillChange fires before the value lands; read it after.
                DispatchQueue.main.async { self?.viewportDidUpdate() }
            }
        }
    }
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            needsDisplay = true
        }
    }
    var nominalSize: CGSize = .zero {
        didSet {
            guard nominalSize != oldValue else { return }
            needsDisplay = true
        }
    }
    /// Crop display: displayed-region origin within the bitmap's canvas,
    /// and that canvas's size (nominalSize is the crop's size).
    var sourceOrigin: CGPoint = .zero {
        didSet { if sourceOrigin != oldValue { needsDisplay = true } }
    }
    var sourceCanvas: CGSize = .zero {
        didSet { if sourceCanvas != oldValue { needsDisplay = true } }
    }
    var sourceAngle: Double = 0 {
        didSet { if sourceAngle != oldValue { needsDisplay = true } }
    }
    private var viewportSubscription: AnyCancellable?
    private var lastScale: CGFloat = -1
    private var lastOffset: CGSize = .zero

    override func layout() {
        super.layout()
        needsDisplay = true  // pane resized; recompute fit and redraw
    }

    /// All interaction happens on the pane's event overlay.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func viewportDidUpdate() {
        guard let viewport, nominalSize != .zero else { return }
        let scale = viewport.effectiveScale(imageSize: nominalSize, viewSize: bounds.size)
        if scale != lastScale || viewport.offset != lastOffset {
            lastScale = scale
            lastOffset = viewport.offset
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(dirtyRect)
        guard let cg = image, let viewport, nominalSize != .zero else { return }
        let scale = viewport.effectiveScale(imageSize: nominalSize, viewSize: bounds.size)
        let canvas = sourceCanvas == .zero ? nominalSize : sourceCanvas
        // originX/Y = view position of the bitmap canvas's pixel (0, 0) in
        // the displayed (possibly cropped) coordinate space.
        let originX = bounds.width / 2
            - (viewport.offset.width + nominalSize.width / 2 + sourceOrigin.x) * scale
        let originY = bounds.height / 2
            - (viewport.offset.height + nominalSize.height / 2 + sourceOrigin.y) * scale
        // Same rule as RetouchCanvas, in bitmap pixels per point because
        // progressive previews arrive at reduced resolution stretched to
        // canvas space (RetouchCanvas's bitmap is always full-res).
        let bitmapScale = canvas.width * scale / CGFloat(max(cg.width, 1))
        ctx.interpolationQuality = bitmapScale >= 2 ? .none : .low
        ctx.saveGState()
        // Clip to the displayed (crop) region: the rotated bitmap extends
        // past it, and unclipped spill renders the "whole image, tilted".
        ctx.clip(to: CGRect(
            x: bounds.width / 2 - (viewport.offset.width + nominalSize.width / 2) * scale,
            y: bounds.height / 2 - (viewport.offset.height + nominalSize.height / 2) * scale,
            width: nominalSize.width * scale,
            height: nominalSize.height * scale))
        if sourceAngle != 0 {
            // Rotate about the crop center's view position (which the
            // origin math keeps at pane center minus the pan offset).
            let cx = bounds.width / 2 - viewport.offset.width * scale
            let cy = bounds.height / 2 - viewport.offset.height * scale
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: -CGFloat(sourceAngle) * .pi / 180)
            ctx.translateBy(x: -cx, y: -cy)
        }
        // draw(_:in:) is bottom-up; re-flip within our flipped coordinates.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: originX,
                                y: bounds.height - originY - canvas.height * scale,
                                width: canvas.width * scale,
                                height: canvas.height * scale))
        ctx.restoreGState()
    }
}

struct TonedImagePane: NSViewRepresentable {
    let image: CGImage
    let nominalSize: CGSize
    var sourceOrigin: CGPoint = .zero
    var sourceCanvas: CGSize = .zero
    var sourceAngle: Double = 0
    let viewport: ViewportState
    let tone: ToneSettings

    func makeNSView(context: Context) -> TonedImagePaneNSView {
        let view = TonedImagePaneNSView()
        // Without this, macOS silently ignores Core Image layer filters.
        view.layerUsesCoreImageFilters = true
        view.viewport = viewport
        view.image = image
        view.nominalSize = nominalSize
        view.sourceOrigin = sourceOrigin
        view.sourceCanvas = sourceCanvas
        view.sourceAngle = sourceAngle
        view.applyTone(tone)
        return view
    }

    func updateNSView(_ view: TonedImagePaneNSView, context: Context) {
        view.viewport = viewport
        view.image = image
        view.nominalSize = nominalSize
        view.sourceOrigin = sourceOrigin
        view.sourceCanvas = sourceCanvas
        view.sourceAngle = sourceAngle
        view.applyTone(tone)
        view.viewportDidUpdate()
    }
}

/// Native event layer: drag-to-pan, two-finger scroll pan, and cursor-anchored
/// pinch zoom — things SwiftUI gestures can't deliver on macOS.
class PanZoomEventView: NSView {
    var viewport: ViewportState?
    var imageSize: CGSize = .zero

    override var isFlipped: Bool { true }  // top-left origin, matching SwiftUI

    override func scrollWheel(with event: NSEvent) {
        guard let viewport, imageSize != .zero else { return }
        viewport.pan(by: CGSize(width: event.scrollingDeltaX,
                                height: event.scrollingDeltaY),
                     imageSize: imageSize, paneSize: bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewport, imageSize != .zero else { return }
        viewport.pan(by: CGSize(width: event.deltaX, height: event.deltaY),
                     imageSize: imageSize, paneSize: bounds.size)
    }

    override func magnify(with event: NSEvent) {
        guard let viewport, imageSize != .zero else { return }
        let location = convert(event.locationInWindow, from: nil)
        viewport.zoom(at: location, in: bounds.size,
                      by: 1 + event.magnification, imageSize: imageSize)
    }

    /// Pane coordinates → image pixel coordinates under the current viewport.
    func imagePoint(from viewPoint: CGPoint) -> CGPoint? {
        guard let viewport, imageSize != .zero else { return nil }
        let scale = viewport.effectiveScale(imageSize: imageSize, viewSize: bounds.size)
        guard scale > 0 else { return nil }
        return CGPoint(
            x: (viewPoint.x - bounds.width / 2) / scale
                + viewport.offset.width + imageSize.width / 2,
            y: (viewPoint.y - bounds.height / 2) / scale
                + viewport.offset.height + imageSize.height / 2)
    }
}

struct PanZoomOverlay: NSViewRepresentable {
    let viewport: ViewportState
    let imageSize: CGSize

    func makeNSView(context: Context) -> PanZoomEventView {
        PanZoomEventView()
    }

    func updateNSView(_ view: PanZoomEventView, context: Context) {
        view.viewport = viewport
        view.imageSize = imageSize
        if view.bounds.size != .zero {
            viewport.lastPaneSize = view.bounds.size
        }
    }
}

/// Retouch-mode event layer: left-drag paints (scroll/pinch still navigate),
/// hover reports the brush location, ↑/↓ cycle source frames, space auto-picks
/// the sharpest source for the brush region.
final class RetouchEventView: PanZoomEventView {
    var onStrokeBegan: ((CGPoint) -> Void)?
    var onStrokeMoved: ((CGPoint, CGPoint) -> Void)?
    var onStrokeEnded: (() -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    var onCycleSource: ((Int) -> Void)?
    var onAutoPick: (() -> Void)?
    var onBrushResize: ((Double) -> Void)?  // multiplicative factor
    var onTogglePMax: (() -> Void)?
    var onToggleResult: (() -> Void)?

    /// Painting happens at a point; the arrow cursor obscures it, the brush
    /// circle only shows the radius.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var lastImagePoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHover?(imagePoint(from: location))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        guard let point = imagePoint(from: location) else { return }
        lastImagePoint = point
        onStrokeBegan?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        // Left-drag paints; panning stays on two-finger scroll / pinch.
        let location = convert(event.locationInWindow, from: nil)
        guard let point = imagePoint(from: location) else { return }
        onHover?(point)
        if let last = lastImagePoint {
            onStrokeMoved?(last, point)
        }
        lastImagePoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastImagePoint = nil
        onStrokeEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        // Option+scroll resizes the brush (the convention Krita/Affinity/GIMP
        // settled on); plain scroll still pans.
        if event.modifierFlags.contains(.option) {
            onBrushResize?(pow(1.015, -event.scrollingDeltaY))
            return
        }
        super.scrollWheel(with: event)
        refreshHover(with: event)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        refreshHover(with: event)
    }

    /// The image moved under a stationary cursor — re-anchor the brush circle
    /// to the image point now under the mouse.
    private func refreshHover(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHover?(imagePoint(from: location))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "[": onBrushResize?(1 / 1.15); return
        case "]": onBrushResize?(1.15); return
        case "p": onTogglePMax?(); return
        case "r": onToggleResult?(); return
        default: break
        }
        switch event.keyCode {
        case 126: onCycleSource?(-1)   // up arrow → previous frame
        case 125: onCycleSource?(1)    // down arrow → next frame
        case 49: onAutoPick?()         // space → sharpest source under brush
        default: super.keyDown(with: event)
        }
    }
}

/// Direct-drawing canvas for the retouch working image: brush stamps invalidate
/// only the view rect they touched, and drawing samples the live byte buffer
/// through a zero-copy CGImage. No per-frame NSImage rebuilds, no full-texture
/// re-uploads — this is what makes 45 MP painting smooth.
final class RetouchCanvasNSView: ToneFilteredPaneView {
    weak var session: RetouchSession?
    /// Depth view: draw the session's live depth visualization instead of
    /// the working pixels (strokes co-paint depth, so it updates as you
    /// paint). The depth map is data, not image content — callers pass a
    /// neutral tone alongside.
    var showDepth = false {
        didSet {
            guard showDepth != oldValue else { return }
            needsDisplay = true
        }
    }
    /// Observed directly via Combine — SwiftUI's updateNSView isn't reliably
    /// re-invoked through the AnyView wrapping when only the viewport changes.
    var viewport: ViewportState? {
        didSet {
            guard viewport !== oldValue else { return }
            viewportSubscription = viewport?.objectWillChange.sink { [weak self] _ in
                // objectWillChange fires before the value lands; read it after.
                DispatchQueue.main.async { self?.viewportDidUpdate() }
            }
        }
    }
    private var viewportSubscription: AnyCancellable?
    private var lastScale: CGFloat = -1
    private var lastOffset: CGSize = .zero

    override func layout() {
        super.layout()
        needsDisplay = true  // pane resized; recompute fit and redraw
    }

    func attach(session: RetouchSession) {
        guard self.session !== session else { return }
        self.session = session
        session.onDisplayDirty = { [weak self] imageRect in
            self?.invalidate(imageRect: imageRect)
        }
        needsDisplay = true
    }

    /// Redraw fully only when the viewport actually moved (cursor-move renders
    /// must not repaint the canvas).
    func viewportDidUpdate() {
        guard let session, let viewport else { return }
        let scale = viewport.effectiveScale(imageSize: session.nominalSize, viewSize: bounds.size)
        if scale != lastScale || viewport.offset != lastOffset {
            lastScale = scale
            lastOffset = viewport.offset
            needsDisplay = true
        }
    }

    private func invalidate(imageRect: CGRect) {
        guard let session, let viewport else { return }
        let imageSize = session.nominalSize
        let scale = viewport.effectiveScale(imageSize: imageSize, viewSize: bounds.size)
        let originX = bounds.width / 2 - (viewport.offset.width + imageSize.width / 2) * scale
        let originY = bounds.height / 2 - (viewport.offset.height + imageSize.height / 2) * scale
        let viewRect = CGRect(x: originX + imageRect.minX * scale,
                              y: originY + imageRect.minY * scale,
                              width: imageRect.width * scale,
                              height: imageRect.height * scale)
            .insetBy(dx: -2, dy: -2)
        setNeedsDisplay(viewRect.intersection(bounds))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(dirtyRect)
        guard let session, let viewport else { return }
        let imageSize = session.nominalSize
        let scale = viewport.effectiveScale(imageSize: imageSize, viewSize: bounds.size)
        let originX = bounds.width / 2 - (viewport.offset.width + imageSize.width / 2) * scale
        let originY = bounds.height / 2 - (viewport.offset.height + imageSize.height / 2) * scale
        ctx.interpolationQuality = scale >= 2 ? .none : .low
        let drawImage: ((CGImage?) -> Void) -> Void = self.showDepth
            ? session.withDepthDisplayCGImage
            : session.withDisplayCGImage
        drawImage { cg in
            guard let cg else { return }
            ctx.saveGState()
            // draw(_:in:) is bottom-up; re-flip within our flipped coordinates.
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            let drawRect = CGRect(x: originX,
                                  y: bounds.height - originY - imageSize.height * scale,
                                  width: imageSize.width * scale,
                                  height: imageSize.height * scale)
            ctx.draw(cg, in: drawRect)
            ctx.restoreGState()
        }
    }
}

struct RetouchCanvas: NSViewRepresentable {
    let session: RetouchSession
    let viewport: ViewportState
    var tone = ToneSettings()
    var showDepth = false

    func makeNSView(context: Context) -> RetouchCanvasNSView {
        let view = RetouchCanvasNSView()
        // Without this, macOS silently ignores Core Image layer filters.
        view.layerUsesCoreImageFilters = true
        view.viewport = viewport
        view.attach(session: session)
        view.showDepth = showDepth
        // The depth map is a data visualization — never tone it.
        view.applyTone(showDepth ? ToneSettings() : tone)
        return view
    }

    func updateNSView(_ view: RetouchCanvasNSView, context: Context) {
        view.viewport = viewport
        view.attach(session: session)
        view.showDepth = showDepth
        view.applyTone(showDepth ? ToneSettings() : tone)
        view.viewportDidUpdate()
    }
}

struct RetouchOverlay: NSViewRepresentable {
    let viewport: ViewportState
    let imageSize: CGSize
    let session: RetouchSession

    func makeNSView(context: Context) -> RetouchEventView {
        let view = RetouchEventView()
        view.onStrokeBegan = { [weak session] in session?.beginStroke(at: $0) }
        view.onStrokeMoved = { [weak session] in session?.continueStroke(from: $0, to: $1) }
        view.onStrokeEnded = { [weak session] in session?.endStroke() }
        view.onHover = { [weak session] in session?.cursor = $0 }
        view.onCycleSource = { [weak session] in session?.cycleSource(by: $0) }
        view.onAutoPick = { [weak session] in
            guard let session, let cursor = session.cursor else { return }
            session.autoPickSource(at: cursor)
        }
        view.onBrushResize = { [weak session] in session?.adjustBrushRadius(by: $0) }
        view.onTogglePMax = { [weak session] in session?.togglePMaxLayer() }
        view.onToggleResult = { [weak session] in session?.toggleResultLayer() }
        return view
    }

    func updateNSView(_ view: RetouchEventView, context: Context) {
        view.viewport = viewport
        view.imageSize = imageSize
        if view.bounds.size != .zero {
            viewport.lastPaneSize = view.bounds.size
        }
    }
}

// MARK: - Labeled slider with help

struct LabeledSlider: View {
    let label: String
    /// Accessibility identifier for the slider (`<id>.value` names the value
    /// text). See CLAUDE.md for the `area.control` naming convention.
    var id: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    /// Multiplier applied to the value for display only (e.g. 100 for percent).
    var displayScale: Double = 1
    let help: String
    var onEditingChanged: ((Bool) -> Void)? = nil

    /// A hair below zero formats as "-0.00" (drag the slider back toward
    /// zero and stop a fraction short) - show the zero it rounds to instead.
    private var displayString: String {
        let s = String(format: format, value * displayScale)
        if s == String(format: format, -0.0) {
            return String(format: format, 0.0)
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help(help)
                Spacer()
                Text(displayString)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(id.map { "\($0).value" } ?? "")
            }
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
            }
            .accessibilityIdentifier(id ?? "")
            .accessibilityLabel(label)
            .accessibilityValue(displayString)
        }
        .help(help)
    }
}

extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }
}


/// Sidebar controls while crop mode is active: aspect constraint,
/// orientation swap (X), Accept (return) / Cancel (escape).
struct CropControls: View {
    @ObservedObject var model: AppModel

    /// A rectangle-with-rotation-arrow symbol when the OS has one; the
    /// plain rotate arrow otherwise.
    private var orientationSymbol: String {
        let preferred = model.cropPortrait
            ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate"
        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil
            ? preferred : "rotate.right"
    }

    var body: some View {
        Text("Crop")
            .font(.headline)
        HStack {
            Picker("Aspect Ratio", selection: $model.cropAspect) {
                ForEach(AppModel.CropAspect.allCases, id: \.self) { aspect in
                    Text(aspect.rawValue).tag(aspect)
                }
            }
            .accessibilityIdentifier("edit.crop-aspect")
            Button {
                model.toggleCropOrientation()
            } label: {
                // Fixed square: the landscape and portrait symbols have
                // different intrinsic sizes, and letting them dictate the
                // button size shifts the row layout on every toggle.
                Image(systemName: orientationSymbol)
                    .frame(width: 18, height: 18)
            }
            .keyboardShortcut("x", modifiers: [])
            .accessibilityIdentifier("edit.crop-orientation")
            .help("Swap the crop between landscape and portrait (X).")
        }
        HStack {
            Button("Accept") { model.acceptCrop() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("edit.crop-accept")
            Button("Cancel") { model.cancelCrop() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("edit.crop-cancel")
        }
        .frame(maxWidth: .infinity)
    }
}

/// Crop-mode event/drawing layer on the output pane: the full canvas is
/// shown behind it; this draws the dimmed surround, the (possibly rotated)
/// crop rectangle and its handles, and turns drags into edits — handles
/// resize in the rect's rotated frame, the interior moves it, anywhere
/// outside rotates it. Every edit is hard-limited: the rect can never
/// leave the image. Replaces PanZoomOverlay while active (crop mode is
/// entered at fit zoom, so pan/zoom isn't needed mid-edit).
final class CropOverlayNSView: NSView {
    var viewport: ViewportState? {
        didSet {
            guard viewport !== oldValue else { return }
            subscription = viewport?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.needsDisplay = true }
            }
        }
    }
    var canvas: CGSize = .zero
    var rect: CGRect = .zero {
        didSet { if rect != oldValue { needsDisplay = true } }
    }
    /// Locked width/height ratio (nil = freeform).
    var aspect: CGFloat?
    /// Rotation in degrees. Convention everywhere (overlay, panes, export
    /// samplers): positive = the crop rect rotated CLOCKWISE on screen
    /// (y-down), about the rect's center.
    var angle: Double = 0 {
        didSet { if angle != oldValue { needsDisplay = true } }
    }
    var onChange: ((CGRect) -> Void)?
    var onAngleChange: ((Double) -> Void)?
    private var subscription: AnyCancellable?
    private enum Drag { case move, handle(dx: Int, dy: Int), rotate }
    private var drag: Drag?
    private var dragStartImage = CGPoint.zero
    private var dragStartRect = CGRect.zero
    private var lastRotateVec: CGPoint?
    /// Unwrapped angles for rotation drags: the target keeps accumulating
    /// even while the rect is wedged against the canvas (windup), and the
    /// applied angle only follows once the target swings back within reach.
    private var rotationTarget = 0.0
    private var rotationApplied = 0.0
    /// The cursor captured at mouse-down, held for the whole drag — without
    /// this the cursor flips to whichever region the pointer wanders into.
    private var dragCursor: NSCursor?

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        needsDisplay = true
    }

    private var scale: CGFloat {
        viewport?.effectiveScale(imageSize: canvas, viewSize: bounds.size) ?? 1
    }
    /// View position of canvas pixel (0, 0).
    private var origin: CGPoint {
        let s = scale
        let off = viewport?.offset ?? .zero
        return CGPoint(x: bounds.width / 2 - (off.width + canvas.width / 2) * s,
                       y: bounds.height / 2 - (off.height + canvas.height / 2) * s)
    }
    private func toView(_ r: CGRect) -> CGRect {
        let s = scale, o = origin
        return CGRect(x: o.x + r.minX * s, y: o.y + r.minY * s,
                      width: r.width * s, height: r.height * s)
    }
    private func toImage(_ p: NSPoint) -> CGPoint {
        let s = scale, o = origin
        return CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s)
    }

    /// A point inverse-rotated about the rect center — hit tests happen in
    /// the crop's unrotated frame (inverse of clockwise-positive is R(-a)).
    private func unrotated(_ p: CGPoint) -> CGPoint {
        guard angle != 0 else { return p }
        let rad = angle * .pi / 180
        let dx = p.x - rect.midX, dy = p.y - rect.midY
        return CGPoint(x: rect.midX + dx * cos(rad) + dy * sin(rad),
                       y: rect.midY - dx * sin(rad) + dy * cos(rad))
    }

    /// Hard containment test: every corner of the rect, rotated about its
    /// center, must lie inside the canvas. All drag operations refuse edits
    /// that would fail this — the crop can never leave the image.
    private func fits(_ r: CGRect, angle: Double) -> Bool {
        guard canvas != .zero else { return false }
        let rad = CGFloat(angle) * .pi / 180
        let c = CGPoint(x: r.midX, y: r.midY)
        let cosA = cos(rad), sinA = sin(rad)
        for corner in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let dx = corner.x - c.x, dy = corner.y - c.y
            let px = c.x + dx * cosA - dy * sinA   // clockwise-positive, y-down
            let py = c.y + dx * sinA + dy * cosA
            if px < -0.5 || py < -0.5 || px > canvas.width + 0.5
                || py > canvas.height + 0.5 {
                return false
            }
        }
        return true
    }

    /// Eight rotation cursors, one per 45-degree sector around the rect
    /// (Lightroom-style; macOS ships no rotation cursor). Index 0 =
    /// top-left, clockwise.
    /// Eight rotation cursors, one per 45-degree sector around the rect
    /// (index 0 = top-left, clockwise). Built from two hand-drawn glyphs —
    /// sector 0 (corner) and sector 1 (edge) — with the remaining six
    /// derived by flips and transposes. Falls back to a generated symbol
    /// cursor if the art is missing from the bundle.
    private static let rotateCursors: [NSCursor] = {
        guard let corner = NSImage(named: "crop-rotate-0"),
              let edge = NSImage(named: "crop-rotate-1") else {
            return fallbackRotateCursors
        }
        // Per-sector: source glyph + point mapping (x', y') as an affine
        // matrix in AppKit's convention (x' = m11·x + m21·y, y' = m12·x + m22·y).
        let sectors: [(NSImage, (CGFloat, CGFloat, CGFloat, CGFloat))] = [
            (corner, (1, 0, 0, 1)),     // 0 top-left: as drawn
            (edge, (1, 0, 0, 1)),       // 1 top: as drawn
            (corner, (-1, 0, 0, 1)),    // 2 top-right: flip H
            (edge, (0, 1, 1, 0)),       // 3 right: transpose
            (corner, (-1, 0, 0, -1)),   // 4 bottom-right: flip both
            (edge, (1, 0, 0, -1)),      // 5 bottom: flip V
            (corner, (1, 0, 0, -1)),    // 6 bottom-left: flip V
            (edge, (0, 1, -1, 0)),      // 7 left: transpose + flip H
        ]
        return sectors.map { source, m in
            let size = NSSize(width: 24, height: 24)
            let image = NSImage(size: size, flipped: false) { rect in
                var transform = NSAffineTransformStruct()
                (transform.m11, transform.m12, transform.m21, transform.m22)
                    = (m.0, m.1, m.2, m.3)
                transform.tX = size.width / 2
                    - (m.0 * size.width / 2 + m.2 * size.height / 2)
                transform.tY = size.height / 2
                    - (m.1 * size.width / 2 + m.3 * size.height / 2)
                let affine = NSAffineTransform()
                affine.transformStruct = transform
                affine.concat()
                source.draw(in: rect)
                return true
            }
            return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        }
    }()

    private static let fallbackRotateCursors: [NSCursor] = {
        let symbol = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90",
                             accessibilityDescription: "rotate")
            ?? NSImage(systemSymbolName: "arrow.clockwise",
                       accessibilityDescription: "rotate")!
        func tinted(_ color: NSColor) -> NSImage {
            let image = NSImage(size: symbol.size)
            image.lockFocus()
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            color.set()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
            image.unlockFocus()
            return image
        }
        let white = tinted(.white)
        let black = tinted(.black)
        return (0..<8).map { sector in
            let size = NSSize(width: 22, height: 22)
            let image = NSImage(size: size, flipped: false) { rect in
                let transform = NSAffineTransform()
                transform.translateX(by: size.width / 2, yBy: size.height / 2)
                transform.rotate(byDegrees: CGFloat(sector) * -45)
                transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
                transform.concat()
                let glyph = rect.insetBy(dx: 3, dy: 3)
                for ox in [-0.8, 0, 0.8] as [CGFloat] {
                    for oy in [-0.8, 0, 0.8] as [CGFloat] where ox != 0 || oy != 0 {
                        white.draw(in: glyph.offsetBy(dx: ox, dy: oy))
                    }
                }
                black.draw(in: glyph)
                return true
            }
            return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
        }
    }()

    private static let handles: [(Int, Int)] =
        [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

    private func handleRect(_ v: CGRect, dx: Int, dy: Int) -> CGRect {
        let cx = v.midX + CGFloat(dx) * v.width / 2
        let cy = v.midY + CGFloat(dy) * v.height / 2
        return CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, canvas != .zero else { return }
        let v = toView(rect)
        let full = toView(CGRect(origin: .zero, size: canvas))
            .intersection(bounds.insetBy(dx: -1, dy: -1))
        let center = CGPoint(x: v.midX, y: v.midY)
        let rotation = CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: CGFloat(angle) * .pi / 180)  // flipped coords: + = clockwise
            .translatedBy(x: -center.x, y: -center.y)
        // Dim what the crop removes: canvas minus the rotated rect, via
        // even-odd fill.
        let dimPath = CGMutablePath()
        dimPath.addRect(full)
        dimPath.addRect(v, transform: rotation)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(dimPath)
        ctx.fillPath(using: .evenOdd)
        ctx.saveGState()
        ctx.concatenate(rotation)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.stroke(v.insetBy(dx: 0.5, dy: 0.5))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        for (dx, dy) in Self.handles {
            ctx.fill(handleRect(v, dx: dx, dy: dy))
        }
        ctx.restoreGState()
    }

    // MARK: Cursors and hit testing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .mouseMoved as well as .cursorUpdate: cursorUpdate only fires on
        // ENTERING a tracking area, and this view is one big area — the
        // cursor must re-evaluate on every move across it.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        cursor(for: region(at: p), at: p).set()
    }

    private enum Region {
        case handle(dx: Int, dy: Int)
        case move
        case rotate
    }

    /// Exact hit test in the rect's rotated frame — cursor updates and
    /// mouse-down share it, so the hover cursor can never disagree with
    /// what a click would grab.
    private func region(at viewPoint: NSPoint) -> Region {
        let pu = unrotated(toImage(viewPoint))
        let vu = toView(CGRect(origin: pu, size: .zero)).origin
        let v = toView(rect)
        for (dx, dy) in Self.handles
        where handleRect(v, dx: dx, dy: dy).insetBy(dx: -4, dy: -4).contains(vu) {
            return .handle(dx: dx, dy: dy)
        }
        return v.contains(vu) ? .move : .rotate
    }

    private func cursor(for region: Region, at viewPoint: NSPoint) -> NSCursor {
        switch region {
        case .move:
            return .openHand
        case .handle(let dx, let dy):
            // Orient by the handle's OUTWARD direction after rotation,
            // quantized to 45-degree sectors (0 = east, clockwise, y-down).
            let rad = CGFloat(angle) * .pi / 180
            let ox = CGFloat(dx) * cos(rad) - CGFloat(dy) * sin(rad)
            let oy = CGFloat(dx) * sin(rad) + CGFloat(dy) * cos(rad)
            let deg = atan2(oy, ox) * 180 / .pi
            let sector = Int((deg + 382.5) / 45) % 8
            switch sector {
            case 0, 4: return .resizeLeftRight
            case 2, 6: return .resizeUpDown
            default:
                if #available(macOS 15, *) {
                    let position: NSCursor.FrameResizePosition =
                        switch sector {
                        case 1: .bottomRight
                        case 3: .bottomLeft
                        case 5: .topLeft
                        default: .topRight
                        }
                    return .frameResize(position: position, directions: .all)
                }
                return .crosshair  // no public diagonal cursor pre-15
            }
        case .rotate:
            // Sector around the rect center picks the orientation-matched
            // rotation cursor.
            let c = toView(rect)
            let deg = atan2(viewPoint.y - c.midY, viewPoint.x - c.midX) * 180 / .pi
            // Sectors are CENTERED on the eight compass directions (index 0
            // = top-left at -135°), so the breakpoints sit half a sector
            // (±22.5°) either side of each center.
            let sector = Int(((deg + 135 + 22.5 + 720)
                .truncatingRemainder(dividingBy: 360)) / 45) % 8
            return Self.rotateCursors[sector]
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if drag != nil {
            dragCursor?.set()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        cursor(for: region(at: p), at: p).set()
    }

    // MARK: Drag operations

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = region(at: p)
        switch hit {
        case .handle(let dx, let dy): drag = .handle(dx: dx, dy: dy)
        case .move: drag = .move
        case .rotate: drag = .rotate
        }
        dragStartImage = toImage(p)
        dragStartRect = rect
        lastRotateVec = CGPoint(x: dragStartImage.x - rect.midX,
                                y: dragStartImage.y - rect.midY)
        rotationTarget = angle
        rotationApplied = angle
        if case .move = hit {
            dragCursor = .closedHand
        } else {
            dragCursor = cursor(for: hit, at: p)
        }
        dragCursor?.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if case .rotate = drag {
            // Rotation stays ON a rotation cursor, but the sector tracks
            // the pointer live so the orientation stays correct while
            // sweeping around the circle.
            cursor(for: .rotate, at: viewPoint).set()
        } else {
            dragCursor?.set()  // move/resize hold their grab cursor
        }
        let raw = toImage(viewPoint)
        let rad = CGFloat(angle) * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        switch drag {
        case .rotate:
            // Incremental signed delta between successive grab vectors
            // (atan2 of cross/dot never crosses a branch cut). y-down:
            // positive cross = clockwise drag = increasing angle. The new
            // angle lands only if the rect still fits — a hard stop.
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let v1 = CGPoint(x: raw.x - c.x, y: raw.y - c.y)
            if let v0 = lastRotateVec {
                let cross = Double(v0.x * v1.y - v0.y * v1.x)
                let dot = Double(v0.x * v1.x + v0.y * v1.y)
                // The target tracks the pointer absolutely (unwrapped):
                // rotation refused at a wedge accumulates as windup that
                // must be unwound before the rect moves again.
                rotationTarget += atan2(cross, dot) * 180 / .pi
                let step = rotationTarget - rotationApplied
                func norm(_ a: Double) -> Double {
                    var a = a.truncatingRemainder(dividingBy: 360)
                    if a > 180 { a -= 360 }
                    if a <= -180 { a += 360 }
                    return a
                }
                if fits(rect, angle: norm(rotationTarget)) {
                    rotationApplied = rotationTarget
                } else if step != 0 {
                    // Wedged: advance flush to the stop (boundary bisection
                    // between the fitting current angle and the target).
                    var lo = 0.0, hi = step
                    for _ in 0..<20 {
                        let mid = (lo + hi) / 2
                        if fits(rect, angle: norm(rotationApplied + mid)) {
                            lo = mid
                        } else {
                            hi = mid
                        }
                    }
                    rotationApplied += lo
                }
                let next = norm(rotationApplied)
                if next != angle {
                    angle = next
                    onAngleChange?(next)
                }
            }
            lastRotateVec = v1
        case .move:
            // The rect follows the pointer in IMAGE space (rotation is
            // about the rect's own center, so translating the stored rect
            // translates the rotated one identically). Containment under
            // pure translation is exactly "the center stays inside a
            // margin rectangle" — the margins are the rotated bounding
            // box's half-extents — so each axis clamps independently to
            // the true boundary instead of refusing whole deltas.
            let hw = dragStartRect.width / 2 * abs(cosA)
                + dragStartRect.height / 2 * abs(sinA)
            let hh = dragStartRect.width / 2 * abs(sinA)
                + dragStartRect.height / 2 * abs(cosA)
            let cx = min(max(dragStartRect.midX + raw.x - dragStartImage.x, hw),
                         canvas.width - hw)
            let cy = min(max(dragStartRect.midY + raw.y - dragStartImage.y, hh),
                         canvas.height - hh)
            // Round to whole pixels toward the interior — .integral rounds
            // OUTWARD, which pushed a corner past the boundary and made the
            // containment check refuse whole events (fast drags stranded
            // the rect short of the edge).
            let x = min(max((cx - dragStartRect.width / 2).rounded(), (hw - dragStartRect.width / 2).rounded(.up)),
                        (canvas.width - hw - dragStartRect.width / 2).rounded(.down))
            let y = min(max((cy - dragStartRect.height / 2).rounded(), (hh - dragStartRect.height / 2).rounded(.up)),
                        (canvas.height - hh - dragStartRect.height / 2).rounded(.down))
            let cand = CGRect(x: x, y: y, width: dragStartRect.width,
                              height: dragStartRect.height)
            if cand != rect {
                rect = cand
                onChange?(cand)
            }
        case .handle(let hx, let hy):
            // Resize in the rect's local (rotated) frame, anchored so the
            // opposite corner/edge stays fixed ON SCREEN: express the
            // pointer relative to the anchor's image position, rotate that
            // vector into the local frame, size from its components, then
            // rebuild the center back in image space.
            let minSize: CGFloat = 32
            let c0 = CGPoint(x: dragStartRect.midX, y: dragStartRect.midY)
            let anchorLocal = CGPoint(x: CGFloat(-hx) * dragStartRect.width / 2,
                                      y: CGFloat(-hy) * dragStartRect.height / 2)
            let anchor = CGPoint(
                x: c0.x + anchorLocal.x * cosA - anchorLocal.y * sinA,
                y: c0.y + anchorLocal.x * sinA + anchorLocal.y * cosA)
            let vx = raw.x - anchor.x, vy = raw.y - anchor.y
            let lx = vx * cosA + vy * sinA    // R(-angle)·v
            let ly = -vx * sinA + vy * cosA
            var newW = hx == 0 ? dragStartRect.width : max(CGFloat(hx) * lx, minSize)
            var newH = hy == 0 ? dragStartRect.height : max(CGFloat(hy) * ly, minSize)
            if let aspect {
                if hy == 0 {
                    newH = newW / aspect
                } else if hx == 0 {
                    newW = newH * aspect
                } else if abs(newW - dragStartRect.width)
                            >= abs(newH - dragStartRect.height) {
                    newH = newW / aspect
                } else {
                    newW = newH * aspect
                }
            }
            let centerLocal = CGPoint(x: hx == 0 ? 0 : CGFloat(hx) * newW / 2,
                                      y: hy == 0 ? 0 : CGFloat(hy) * newH / 2)
            let newCenter = CGPoint(
                x: anchor.x + centerLocal.x * cosA - centerLocal.y * sinA,
                y: anchor.y + centerLocal.x * sinA + centerLocal.y * cosA)
            let cand = CGRect(x: newCenter.x - newW / 2, y: newCenter.y - newH / 2,
                              width: newW, height: newH).integral
            if fits(cand, angle: angle), cand != rect {
                rect = cand
                onChange?(cand)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        dragCursor = nil
    }
}

struct CropOverlay: NSViewRepresentable {
    let viewport: ViewportState
    let canvas: CGSize
    var aspect: CGFloat? = nil
    @Binding var rect: CGRect?
    @Binding var angle: Double

    func makeNSView(context: Context) -> CropOverlayNSView {
        let view = CropOverlayNSView()
        view.viewport = viewport
        view.canvas = canvas
        view.aspect = aspect
        view.rect = rect ?? CGRect(origin: .zero, size: canvas)
        view.angle = angle
        view.onChange = { rect = $0 }
        view.onAngleChange = { angle = $0 }
        return view
    }

    func updateNSView(_ view: CropOverlayNSView, context: Context) {
        view.viewport = viewport
        view.canvas = canvas
        view.aspect = aspect
        view.onChange = { rect = $0 }
        view.onAngleChange = { angle = $0 }
        if let rect, rect != view.rect { view.rect = rect }
        if angle != view.angle { view.angle = angle }
    }
}
