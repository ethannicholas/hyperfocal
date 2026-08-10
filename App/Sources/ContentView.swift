import SwiftUI
import HyperfocalKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Hand-rolled splitter, not HSplitView: the sidebar must open at its
        // persisted width, and HSplitView offers no control over that — it
        // ignores idealWidth and re-derives pane sizes from min/max
        // constraints on every layout pass (stretching the sidebar to
        // maxWidth; to minWidth with a layoutPriority on the preview), and
        // it overrides NSSplitView.setPosition on the next pass (all
        // measured). A fixed-width sidebar plus a draggable divider gives
        // the launch width exactly and sends window-resize slack to the
        // preview, matching the Qt shell.
        HStack(spacing: 0) {
            sidebar
                .frame(width: model.sidebarWidth)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            previewSide
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        // The grab strip overlays BOTH panes, centered on the hairline. As
        // a sibling between the panes it was topmost over the sidebar but
        // under the preview's event views (AppKit z-order follows sibling
        // order), so a mouse-down in the strip's right half went to the
        // pane — about half of drag attempts were dead, seemingly at
        // random. An overlay on the whole split container is above both.
        .overlay(alignment: .leading) {
            SidebarSplitter(width: $model.sidebarWidth)
                .offset(x: model.sidebarWidth + 0.5 - SidebarSplitter.grabWidth / 2)
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

    /// The Stack card lives outside the Form: a List nested in a grouped
    /// Form loses its scrolling entirely — wheel events over it are
    /// swallowed dead (they don't even reach the form's own scroll view)
    /// and `proxy.scrollTo` is a no-op, both remeasured when this layout
    /// last changed. Its card chrome is therefore hand-drawn to match the
    /// form's (see `cardStyled`).
    private var sidebar: some View {
        VStack(spacing: 0) {
            stackPanel
            Form {
                fusionSection
                toneSection
                retouchSection
                exportSection
            }
            .formStyle(.grouped)
            // New identity per project: a fresh form starts scrolled to the
            // top (a leftover scroll position from the last project would
            // hide the Fusion controls). All form state is model-backed, so
            // nothing else is lost in the rebuild.
            .id(model.projectGeneration)
        }
    }

    /// The grouped-form card look, replicated for the one section that can't
    /// live in the Form (above). `.background.secondary` matches the form's
    /// card fill within 1/255 in both light and dark (measured against
    /// live renders); insets and radius likewise mirror the form's.
    private func cardStyled<T: View>(@ViewBuilder _ content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(.background.secondary)
            // Clip content too (the frame List runs to the card's bottom
            // edge), not just the fill.
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.top, 20)
    }

    /// The form's inter-row separator, replicated (Divider alone is twice as
    /// bright — the form draws its rules at half strength in both schemes).
    private var cardSeparator: some View {
        Divider().opacity(0.5).padding(.horizontal, 10)
    }

    /// Leading indent that aligns a row's label with the header's TITLE
    /// (not its chevron): the chevron glyph's width (caption semibold)
    /// plus the header HStack's 5pt spacing, measured against live
    /// renders. Applied to the labeled rows (sliders, pickers) — the
    /// full-width action buttons keep the plain row inset.
    private var sectionRowIndent: CGFloat { 16.5 }

    private var stackPanel: some View {
        cardStyled {
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
                        Text(model.stacks.count > 1 ? UIStrings.stackPlural : UIStrings.stackSingular).font(.headline)
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
                        Button(UIStrings.includeAllFrames) { model.includeAll(true) }
                            .controlSize(.small)
                            .disabled(model.phase.isRunning)
                            .accessibilityIdentifier("stack.include-all")
                        Button(UIStrings.includeNoFrames) { model.includeAll(false) }
                            .controlSize(.small)
                            .disabled(model.phase.isRunning)
                            .accessibilityIdentifier("stack.include-none")
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)

            if model.isCollapsed(.stack) {
                EmptyView()
            } else if model.stacks.isEmpty {
                cardSeparator
                VStack(spacing: 10) {
                    Text(UIStrings.dropFolderHint)
                        .foregroundStyle(.secondary)
                    Button(UIStrings.openFolder) { model.openFrames() }
                        .accessibilityIdentifier("stack.open-folder")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                cardSeparator
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
                                    .accessibilityLabel(expanded
                                        ? "Collapse \(stack.name)"
                                        : "Expand \(stack.name)")
                                    StackRow(stack: stack,
                                             isSelected: stack.id == model.selectedStackID,
                                             status: model.status(of: stack),
                                             thumbnail: model.stackThumbnails[stack.id],
                                             isRunning: model.phase.isRunning,
                                             setEnabled: { model.setStackEnabled(stack.id, to: $0) },
                                             select: { model.selectStack(stack.id) })
                                        .onAppear { model.requestStackThumbnail(for: stack.id) }
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
                    // Let the card fill show through — the list's own
                    // backdrop is the window background, visibly darker.
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140, idealHeight: 280, maxHeight: 360)
                    .onChange(of: model.selection) { _, newValue in
                        model.selectionChanged()
                        // Multi-selection (fusion progress selects every frame
                        // in flight): Set.first is arbitrary, so anchor on the
                        // LAST selected frame in list order. Scrolled minimally
                        // into view it lands at the viewport's bottom edge,
                        // which keeps the earlier rows of the working band
                        // visible above it — anchoring the first row instead
                        // parks it at the bottom and hides the rest of the
                        // band below the fold.
                        if let url = model.frames.last(where: newValue.contains)
                            ?? newValue.first {
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
                    .onChange(of: model.projectGeneration) {
                        // A replaced project must not inherit the previous
                        // one's scroll offset (the List survives the swap, so
                        // a new import used to arrive scrolled wherever the
                        // old project left it). Same targeting as onAppear —
                        // a restored selection's header, else the first row —
                        // but unconditional: the list may sit anywhere.
                        // Deferred a tick for the same layout reason, which
                        // also lets this outrank the selection-driven
                        // scrollTo firing in the same update.
                        DispatchQueue.main.async {
                            if model.stacks.count > 1 {
                                if let stackID = model.selectedStackID
                                    ?? model.stacks.first?.id {
                                    proxy.scrollTo(stackID, anchor: .top)
                                }
                            } else if let first = model.frames.first {
                                proxy.scrollTo(first, anchor: .top)
                            }
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
                // Checkboxes lock during a fuse (the model ignores them
                // anyway — the run and the batch queue must not shift under
                // a running fuse); dimming stays tied to stack enablement.
                .disabled(!enabled || model.phase.isRunning)
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
    /// buttons inside a button label breaks hit-testing. Rendered as the
    /// section's FIRST ROW (inside the card), not its `header:` — matching
    /// the Stack card, so every title sits on its card's background at the
    /// same leading edge.
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
                    // Font pinned (matching the Stack card's header): a form
                    // ROW styles its text as body — the title must keep the
                    // header weight itself.
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("section.\(section.rawValue)")
            .accessibilityLabel(Text(title))
            .accessibilityValue(model.isCollapsed(section) ? "collapsed" : "expanded")
            trailing()
        }
    }

    private func sectionHeader(_ title: String,
                               _ section: AppModel.SidebarSection) -> some View {
        sectionHeader(title, section) { EmptyView() }
    }

    private func algorithmTooltip(_ method: FusionMethod) -> String {
        switch method {
        case .dmap:
            return UIStrings.algorithmDMapTip
        case .pmax:
            return UIStrings.algorithmPMaxTip
        }
    }

    private var fusionSection: some View {
        // Set-and-forget switches (alignment, GPU, exposure normalization)
        // live in Settings (⌘,); the sidebar keeps the per-stack creative
        // controls.
        Section {
            sectionHeader(UIStrings.fusionSectionTitle, .fusion) {
                if !model.fusionSettingsAreDefault {
                    Button(UIStrings.reset) { model.resetFusionSettings() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .disabled(model.phase.isRunning)
                        .accessibilityIdentifier("fusion.reset")
                }
            }
            if !model.isCollapsed(.fusion) {
            // Algorithm selector: DMap (depth map) vs PMax (pyramid fusion),
            // each with an info tooltip. Only DMap carries depth (depth view,
            // rocking, depth-aware retouch); the picker sets the NEXT fuse.
            // LabeledContent puts "Algorithm:" in the Form's label column and
            // the stacked radios in its content column — lined up with the
            // sliders below.
            LabeledContent(UIStrings.algorithmLabel) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(FusionMethod.allCases, id: \.self) { method in
                        Button {
                            model.fusionMethod = method
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: model.fusionMethod == method
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model.fusionMethod == method
                                                     ? Color.accentColor : Color.secondary)
                                Text(method.displayName).foregroundStyle(.primary)
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary).font(.caption)
                                    .infoTip(algorithmTooltip(method))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("fusion.method.\(method.rawValue)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, sectionRowIndent)
            .disabled(model.phase.isRunning)

            // Locked during a fuse: the run uses the values it started with,
            // so edits mid-run would neither affect it nor be recorded. The
            // per-algorithm sliders swap with the selected method.
            Group {
            if model.fusionMethod == .dmap {
            LabeledSlider(
                label: UIStrings.sliderSharpnessLabel, id: "fusion.slider.sharpness", value: $model.sharpnessSigma, range: 1...16,
                format: "%.1f px",
                help: UIStrings.sliderSharpnessTip)
            LabeledSlider(
                label: UIStrings.sliderNoiseFloorLabel, id: "fusion.slider.noise-floor", value: $model.noiseFloor, range: 0.01...1,
                format: "%.0f%%", displayScale: 100,
                help: UIStrings.sliderNoiseFloorTip,
                onEditingChanged: { editing in
                    if editing {
                        model.beginNoiseFloorPreview()
                    } else {
                        model.endNoiseFloorPreview()
                    }
                })
            LabeledSlider(
                label: UIStrings.sliderMedianRadiusLabel, id: "fusion.slider.median-radius", value: $model.medianRadius, range: 0...32,
                format: "%.0f px",
                help: UIStrings.sliderMedianRadiusTip)
            LabeledSlider(
                label: UIStrings.sliderBlendRadiusLabel, id: "fusion.slider.blend-radius", value: $model.blendRadius,
                range: Double(DMapFusion.minBlendRadius)...4,
                format: "%.2f",
                help: UIStrings.sliderBlendRadiusTip)
            } else {
            LabeledSlider(
                label: UIStrings.sliderDebloomLevelsLabel, id: "fusion.slider.debloom-levels",
                value: Binding(get: { Double(model.pmaxCoarseLevels) },
                               set: { model.pmaxCoarseLevels = Int($0.rounded()) }),
                range: 0...8, format: "%.0f",
                help: UIStrings.sliderDebloomLevelsTip)
            LabeledSlider(
                label: UIStrings.sliderFocusThresholdLabel, id: "fusion.slider.focus-threshold", value: $model.pmaxFocusThreshold,
                range: 0...0.3, format: "%.2f",
                help: UIStrings.sliderFocusThresholdTip)
            }
            }
            .padding(.leading, sectionRowIndent)
            .disabled(model.phase.isRunning)

            Button {
                model.fuse()
            } label: {
                Label(UIStrings.fuseStack, systemImage: "square.3.layers.3d.down.forward")
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
                .help(UIStrings.fuseEnabledStacksTip)
            }
            }
        }
    }

    private var toneSection: some View {
        Section {
            sectionHeader(UIStrings.toneSectionTitle, .tone) {
                if !model.tone.isNeutral {
                    Button(UIStrings.reset) { model.resetTone() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("tone.reset")
                }
            }
            if !model.isCollapsed(.tone) {
            Group {
            LabeledSlider(
                label: UIStrings.sliderExposureLabel, id: "tone.slider.exposure", value: $model.tone.exposure, range: -5...5,
                format: "%+.2f EV",
                help: UIStrings.sliderExposureTip,
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: UIStrings.sliderContrastLabel, id: "tone.slider.contrast", value: $model.tone.contrast, range: -100...100,
                format: "%+.0f",
                help: UIStrings.sliderContrastTip,
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: UIStrings.sliderHighlightsLabel, id: "tone.slider.highlights", value: $model.tone.highlights, range: -100...100,
                format: "%+.0f",
                help: UIStrings.sliderHighlightsTip,
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: UIStrings.sliderShadowsLabel, id: "tone.slider.shadows", value: $model.tone.shadows, range: -100...100,
                format: "%+.0f",
                help: UIStrings.sliderShadowsTip,
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: UIStrings.sliderWhitesLabel, id: "tone.slider.whites", value: $model.tone.whites, range: -100...100,
                format: "%+.0f",
                help: UIStrings.sliderWhitesTip,
                onEditingChanged: { model.toneEditing($0) })
            LabeledSlider(
                label: UIStrings.sliderBlacksLabel, id: "tone.slider.blacks", value: $model.tone.blacks, range: -100...100,
                format: "%+.0f",
                help: UIStrings.sliderBlacksTip,
                onEditingChanged: { model.toneEditing($0) })
            }
            .padding(.leading, sectionRowIndent)
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
            sectionHeader(UIStrings.editSectionTitle, .retouch)
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
                        Label(UIStrings.cropButton, systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(!model.canCrop)
                    .accessibilityIdentifier("edit.crop")
                    .help(UIStrings.cropTip)
                    Button {
                        model.enterRetouch()
                    } label: {
                        Label(model.retouch?.hasEdits == true
                                ? UIStrings.continueRetouching
                                : UIStrings.startRetouching,
                              systemImage: "paintbrush.pointed")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(!model.canStartRetouch)
                    .accessibilityIdentifier("retouch.start")
                }
            }
        }
    }

    private var exportSection: some View {
        Section {
            sectionHeader(UIStrings.exportSectionTitle, .export)
            if !model.isCollapsed(.export) {
            // Format and color space live in the export dialogs themselves
            // (ExportOptionsView in MacDialogService.swift) — the options sit
            // next to the decision they affect, Photoshop-style.
            Button {
                model.exportResult()
            } label: {
                Label(model.outputMode == .depth ? UIStrings.exportDepthMap : UIStrings.exportResult,
                      systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canExport)
            .accessibilityIdentifier("export.result")

            Button {
                model.exportAnimation()
            } label: {
                Label(UIStrings.exportRockingAnimation, systemImage: "video")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canAnimate)
            .accessibilityIdentifier("export.animate")
            .help(UIStrings.exportRockingAnimationTip)

            if model.fusedStackCount > 1 {
                Button {
                    model.exportAllFusedPanel()
                } label: {
                    Label(UIStrings.exportAllFused, systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.phase.isRunning)
                .accessibilityIdentifier("export.all")
                .help(UIStrings.exportAllFusedTip)
            }
            }
        }
    }

    // MARK: - Preview side

    private var previewSide: some View {
        VStack(spacing: 0) {
            if model.retouchMode, let session = model.retouch {
                RetouchPreviewArea(session: session, tone: model.tone,
                                   crop: model.displayCrop,
                                   cropAngle: model.displayCropAngle,
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
                            ? String(localized: "Start a new project to begin")
                            : UIStrings.selectFrameHint),
                    tone: model.tone,
                    header: { EmptyView() }
                )
                PreviewPane(
                    title: UIStrings.outputTitle,
                    paneID: "output.pane",
                    image: outputImage,
                    nominalSize: model.displayCrop?.size ?? model.outputNominalSize,
                    sourceOrigin: model.displayCrop?.origin ?? .zero,
                    sourceCanvas: model.outputNominalSize,
                    sourceAngle: model.displayCropAngle,
                    loading: false,
                    emptyHint: model.canFuse ? UIStrings.pressFuseStackHint
                        : UIStrings.noOutputYet,
                    tone: outputPaneShowsData ? ToneSettings() : model.tone,
                    eventOverlay: model.cropMode ? AnyView(CropOverlay(
                        viewport: model.viewport,
                        canvas: model.outputNominalSize ?? .zero,
                        aspect: model.cropAspectRatio,
                        rect: $model.cropRect,
                        angle: $model.cropAngle)) : nil,
                    header: {
                        Picker("", selection: $model.outputMode) {
                            ForEach(AppModel.OutputMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
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
                                Button(UIStrings.cancel) { model.cancelFusion() }
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
        // Depth comes from the DMap pass; under PMax it may not exist yet, so
        // fall back to the result image rather than showing an empty pane.
        if model.outputMode == .depth, let depth = model.depthPreview { return depth }
        return model.outputPreview
    }

    /// True when the output pane is showing a data visualization — the depth
    /// map, the noise-floor preview, or a non-render progressive (the
    /// aligner's gradient image, the depth map forming) — rather than image
    /// pixels. Tone applies to pixels only; visualizations render exactly
    /// as computed.
    private var outputPaneShowsData: Bool {
        if model.noiseFloorPreview != nil { return true }
        if model.phase.isRunning { return model.progressiveIsData }
        return model.outputMode == .depth
    }

    // During a run, the input pane cycles through frames as they're processed.
    private var showProcessingSource: Bool {
        model.phase.isRunning && model.processingSource != nil
    }

    // Composed in the model (shared with the Qt shell via hf_input_title) so
    // the aligned marker can never diverge between shells or code paths.
    private var inputPaneTitle: String {
        model.inputPaneTitle ?? UIStrings.inputTitle
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
    /// Crop presentation (nil = full canvas). The session — strokes,
    /// cursor, tiles — stays in full-image coordinates throughout; the
    /// panes display the crop exactly like the fusion panes do.
    var crop: CGRect? = nil
    var cropAngle: Double = 0
    /// The Result/Depth toggle stays available while retouching: strokes
    /// co-paint the depth plane, so depth artifacts (which the rocking
    /// animation turns into motion) are fixed with the depth view live.
    @Binding var outputMode: AppModel.OutputMode

    var body: some View {
        let nominal = crop?.size ?? session.nominalSize
        HStack(spacing: 1) {
            PreviewPane(
                title: String(localized: "Source: \(session.sourceName)  ↑/↓ cycle · space picks sharpest"),
                image: session.sourceDisplay,
                nominalSize: nominal,
                sourceOrigin: crop?.origin ?? .zero,
                sourceCanvas: session.nominalSize,
                sourceAngle: cropAngle,
                loading: session.sourceLoading,
                emptyHint: session.sourceError ?? UIStrings.loadingSource,
                loadingStatus: session.sourceStatus,
                brushCursor: brushCursor,
                tone: session.sourceShowsData ? ToneSettings() : tone,
                header: { EmptyView() }
            )
            PreviewPane(
                title: outputMode == .depth
                    ? String(localized: "Retouched Depth — drag to paint from source")
                    : UIStrings.retouchedOutputHint,
                image: nil,
                nominalSize: nominal,
                loading: false,
                emptyHint: "",
                brushCursor: brushCursor,
                eventOverlay: AnyView(
                    RetouchOverlay(viewport: viewport,
                                   imageSize: nominal,
                                   session: session,
                                   cropOrigin: crop?.origin ?? .zero,
                                   cropAngle: cropAngle,
                                   panModifierHeld: $panModifierHeld)),
                canvas: AnyView(RetouchCanvas(session: session, viewport: viewport,
                                              tone: tone,
                                              showDepth: outputMode == .depth,
                                              cropRect: crop,
                                              cropAngle: cropAngle)),
                header: {
                    Picker("", selection: $outputMode) {
                        ForEach(AppModel.OutputMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
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

    /// Drag mode (⌘ held): the next drag pans, so nothing would paint and
    /// the hand cursor says so — a brush ring under it would say the
    /// opposite. View-layer state, like the pan it describes.
    @State private var panModifierHeld = false

    /// Only offered when a stroke would actually paint — no circle over a
    /// still-loading source, and none for the rest of a drag that started
    /// before the source arrived. The session cursor is a full-image point;
    /// the panes draw in displayed (crop) space.
    private var brushCursor: (point: CGPoint, radius: CGFloat)? {
        guard session.canPaint, !panModifierHeld else { return nil }
        return session.cursor.map { (displayedPoint(from: $0), CGFloat(session.brushRadius)) }
    }

    /// Full-image → displayed (inverse of RetouchEventView.fullImagePoint).
    private func displayedPoint(from full: CGPoint) -> CGPoint {
        guard let crop else { return full }
        let bx = full.x - crop.midX
        let by = full.y - crop.midY
        let rad = CGFloat(cropAngle) * .pi / 180
        return CGPoint(x: crop.width / 2 + bx * cos(rad) + by * sin(rad),
                       y: crop.height / 2 - bx * sin(rad) + by * cos(rad))
    }

    @EnvironmentObject var viewport: ViewportState
}

// MARK: - Retouch controls

struct RetouchControls: View {
    @ObservedObject var session: RetouchSession
    let onDone: () -> Void
    let onReset: () -> Void

    var body: some View {
        Text(UIStrings.retouchingTitle)
            .font(.headline)
        LabeledSlider(
            label: UIStrings.sliderBrushSizeLabel, id: "retouch.slider.brush-size", value: $session.brushRadius,
            range: RetouchSession.brushRadiusRange,
            format: "%.0f px",
            help: UIStrings.sliderBrushSizeTip)
        LabeledSlider(
            label: UIStrings.sliderSoftnessLabel, id: "retouch.slider.softness", value: $session.brushSoftness, range: 0...1,
            format: "%.0f%%", displayScale: 100,
            help: UIStrings.sliderSoftnessTip)
        Picker(UIStrings.retouchFromLabel, selection: Binding(
            get: { session.sourceKind },
            set: { session.selectKind($0) })) {
            Text(UIStrings.retouchSourceImage).tag(RetouchSession.SourceKind.frame)
            Text(UIStrings.retouchPMaxResult).tag(RetouchSession.SourceKind.pmax)
            Text(UIStrings.retouchDMapResult).tag(RetouchSession.SourceKind.dmap)
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("retouch.source-kind")
        .help(UIStrings.retouchSourceTip)
        HStack {
            Spacer()
            Button(UIStrings.revertAll, role: .destructive) { onReset() }
                .disabled(!session.hasEdits)
                .accessibilityIdentifier("retouch.revert-all")
        }
        Text("↑/↓ cycle source frames · space picks the sharpest frame for the brush region · p PMax result · r eraser · ⌥-scroll or [ ] resize the brush · scroll/pinch to navigate")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button {
            onDone()
        } label: {
            Label(UIStrings.doneRetouching, systemImage: "checkmark.circle")
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
            Text(UIStrings.zoomLabel)
                .foregroundStyle(.secondary)
            Menu {
                Button(UIStrings.zoomFit) { viewport.reset() }
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
        case .fit: return UIStrings.zoomFit
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
    /// The stack's middle-frame thumbnail (AppModel.stackThumbnails) —
    /// replaces the generic stack glyph once it has decoded.
    let thumbnail: CGImage?
    /// Locks the enable checkbox during a fuse — enabled-ness decides batch
    /// queue membership, so it must not move under a running fuse (the model
    /// ignores the toggle then; this greys the control to say so).
    let isRunning: Bool
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
                .disabled(isRunning)
                .help(UIStrings.includeStackTip)
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
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.separator, lineWidth: 0.5))
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.title2)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 60, height: 42)
                    }
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
                .help(UIStrings.fusedStatusTip)
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
            PerfLog.span("pane: build color cube") {
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
    /// Retouch shows a second full-res pane (the brush source) alongside the
    /// canvas; its first draw is on the same latency path (see PerfLog).
    private var loggedFirstDraw = false

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
        let drawRect = CGRect(x: originX,
                              y: bounds.height - originY - canvas.height * scale,
                              width: canvas.width * scale,
                              height: canvas.height * scale)
        // Same rule as RetouchCanvasNSView: only a draw that reaches the
        // screen is on the latency path.
        if loggedFirstDraw || drawRect.isEmpty || dirtyRect.isEmpty {
            ctx.draw(cg, in: drawRect)
        } else {
            loggedFirstDraw = true
            PerfLog.span("pane: first ctx.draw \(cg.width)×\(cg.height)"
                         + " → \(Int(dirtyRect.width))×\(Int(dirtyRect.height)) pt") {
                ctx.draw(cg, in: drawRect)
            }
            PerfLog.mark("pane: first draw done")
        }
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

    /// Middle-drag pans in every mode — including retouch, where left-drag
    /// is painting and a mouse user would otherwise have only the wheel.
    /// The Qt shell's panes already accept it (`PaneItem` takes
    /// `LeftButton | MiddleButton`); side buttons are left alone.
    static func isMiddleButton(_ event: NSEvent) -> Bool {
        event.buttonNumber == 2
    }

    /// Claiming the press is what makes the drag events follow: the default
    /// implementation hands them to the next responder instead.
    override func otherMouseDown(with event: NSEvent) {
        guard Self.isMiddleButton(event) else {
            super.otherMouseDown(with: event)
            return
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard Self.isMiddleButton(event) else {
            super.otherMouseDragged(with: event)
            return
        }
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
    var onToggleDMap: (() -> Void)?
    var onToggleResult: (() -> Void)?
    /// Crop presentation: `imageSize` is the displayed (cropped) space, but
    /// the session — strokes, cursor, tiles — lives in full-image
    /// coordinates. These describe the crop so events can convert.
    var cropOrigin: CGPoint = .zero
    var cropAngle: Double = 0

    /// Displayed (crop-space) point → full-image point. Same mapping as
    /// AppModel.cropped's sampling: b = center + R(angle)·(d − size/2).
    /// Identity when no crop is shown (origin zero, angle zero).
    func fullImagePoint(from displayed: CGPoint) -> CGPoint {
        let dx = displayed.x - imageSize.width / 2
        let dy = displayed.y - imageSize.height / 2
        let cx = cropOrigin.x + imageSize.width / 2
        let cy = cropOrigin.y + imageSize.height / 2
        guard cropAngle != 0 else { return CGPoint(x: cx + dx, y: cy + dy) }
        let rad = CGFloat(cropAngle) * .pi / 180
        return CGPoint(x: cx + dx * cos(rad) - dy * sin(rad),
                       y: cy + dx * sin(rad) + dy * cos(rad))
    }


    /// The paint cursor. `NSCursor.crosshair` is a solid black cross, which
    /// disappears over the dark parts of an image — for a stacked subject on
    /// a black backdrop, most of the frame. This is the same cross under a
    /// white halo, so whichever the background, one of the two contrasts with
    /// it; the centre stays transparent so the cursor never covers the pixel
    /// it aims at. The Qt shell draws the same glyph at the same measurements
    /// (Shell.cpp's `crosshairCursor()`) — one cursor, two shells.
    /// A 24pt grid of 1pt cells, so every edge lands on a device pixel at 1x
    /// and 2x alike — a 1pt line centred on a 24pt cursor would straddle two
    /// pixels at 1x and blur the core into its halo, which is what the Qt
    /// shell's first attempt did on a 1x screen (grey arms, white tips). The
    /// core is the cell at 12, half a point off the hotspot: invisible, and
    /// the price of an odd-width line on an even grid.
    static let paintCursor: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        // White first and 1pt proud of the black on every side, so what is
        // left once the core is drawn down its middle is the halo.
        let arms: [(from: CGFloat, to: CGFloat, edge: CGFloat, width: CGFloat,
                    color: NSColor)] =
            [(1, 11, 11, 3, .white), (2, 10, 12, 1, .black)]
        let image = NSImage(size: size, flipped: false) { _ in
            for arm in arms {
                arm.color.setFill()
                let length = arm.to - arm.from
                // The opposite arm, reflected through the core's centre line
                // at cell 12.5: a span [from, to) becomes [25 - to, 25 - from).
                let mirror = 25 - arm.to
                NSRect(x: arm.from, y: arm.edge, width: length, height: arm.width).fill()
                NSRect(x: mirror, y: arm.edge, width: length, height: arm.width).fill()
                NSRect(x: arm.edge, y: arm.from, width: arm.width, height: length).fill()
                NSRect(x: arm.edge, y: mirror, width: arm.width, height: length).fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()

    /// Painting happens at a point; the arrow cursor obscures it, the brush
    /// circle only shows the radius. In drag mode it becomes a hand, open
    /// until the pan is actually under way.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: panModifierHeld ? .openHand : Self.paintCursor)
    }

    /// ⌘ held: the next left-drag pans instead of painting. Ctrl is not
    /// available for this on macOS (Ctrl-click is the system secondary
    /// click) and space is already auto-pick, so ⌘ is the free modifier —
    /// and it is what the Qt shell's Ctrl-drag already resolves to here, so
    /// the two shells describe one gesture.
    var onPanModifier: ((Bool) -> Void)?
    private var isPanning = false
    private var panModifierHeld = false {
        didSet {
            guard panModifierHeld != oldValue else { return }
            onPanModifier?(panModifierHeld)
            window?.invalidateCursorRects(for: self)
            // Cursor rects are only re-run on the next mouse-moved event,
            // and drag mode is entered with the pointer standing still.
            if !isPanning { setCursorForModifier() }
        }
    }

    private func setCursorForModifier() {
        (panModifierHeld ? NSCursor.openHand : Self.paintCursor).set()
    }

    override func flagsChanged(with event: NSEvent) {
        panModifierHeld = event.modifierFlags.contains(.command)
        super.flagsChanged(with: event)
    }

    private var lastImagePoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    /// Retouch keys (P/D/R, arrows, space) reach only the first responder,
    /// and until this view holds it they beep. Mouse entry claims it below,
    /// but entering retouch mode from a button click leaves the pointer
    /// outside the canvas — claim it the moment the overlay joins the
    /// window, async so it lands after SwiftUI finishes installing the
    /// hierarchy. (The Qt shell needs no equivalent: its retouch keys are
    /// window-level Shortcuts, active regardless of focus.)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

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
        // flagsChanged only reaches the first responder, so ⌘ going down
        // over another window leaves nothing behind; the current flags are
        // the only evidence it is held, and a press would already pan.
        panModifierHeld = NSEvent.modifierFlags.contains(.command)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        panModifierHeld = event.modifierFlags.contains(.command)
        let location = convert(event.locationInWindow, from: nil)
        onHover?(imagePoint(from: location).map(fullImagePoint(from:)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        panModifierHeld = event.modifierFlags.contains(.command)
        if panModifierHeld {
            isPanning = true
            NSCursor.closedHand.set()
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard let point = imagePoint(from: location).map(fullImagePoint(from:))
        else { return }
        lastImagePoint = point
        onStrokeBegan?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        // Left-drag paints, unless ⌘ put the canvas in drag mode; panning
        // is otherwise two-finger scroll / pinch (or middle-drag).
        if isPanning {
            // Cursor rects are suspended for the length of a drag, so the
            // closed hand has to be set rather than declared.
            NSCursor.closedHand.set()
            super.mouseDragged(with: event)
            refreshHover(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard let point = imagePoint(from: location).map(fullImagePoint(from:))
        else { return }
        onHover?(point)
        if let last = lastImagePoint {
            onStrokeMoved?(last, point)
        }
        lastImagePoint = point
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            panModifierHeld = event.modifierFlags.contains(.command)
            setCursorForModifier()
            window?.invalidateCursorRects(for: self)
            return
        }
        lastImagePoint = nil
        onStrokeEnded?()
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        if Self.isMiddleButton(event) { NSCursor.closedHand.set() }
    }

    override func otherMouseDragged(with event: NSEvent) {
        super.otherMouseDragged(with: event)
        guard Self.isMiddleButton(event) else { return }
        NSCursor.closedHand.set()
        refreshHover(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard Self.isMiddleButton(event) else {
            super.otherMouseUp(with: event)
            return
        }
        setCursorForModifier()
        window?.invalidateCursorRects(for: self)
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
        onHover?(imagePoint(from: location).map(fullImagePoint(from:)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "[": onBrushResize?(1 / 1.15); return
        case "]": onBrushResize?(1.15); return
        case "p": onTogglePMax?(); return
        case "d": onToggleDMap?(); return
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
    /// Crop presentation (same scheme as TonedImagePaneNSView): the session
    /// bitmap stays full-canvas, but the displayed coordinate space is the
    /// crop — nil shows the whole canvas. Strokes and tiles keep full-image
    /// coordinates; only drawing shifts, rotates, and clips.
    var cropRect: CGRect? {
        didSet { if cropRect != oldValue { needsDisplay = true } }
    }
    var cropAngle: Double = 0 {
        didSet { if cropAngle != oldValue { needsDisplay = true } }
    }
    /// The displayed (pan/zoom) coordinate space: the crop when one is set.
    private var displaySize: CGSize {
        cropRect?.size ?? session?.nominalSize ?? .zero
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
    /// The Start Retouching latency measurement ends at the first completed
    /// draw — that is when the user sees the canvas (see PerfLog).
    private var loggedFirstDraw = false
    private var loggedFirstLayout = false

    override func layout() {
        super.layout()
        if !loggedFirstLayout, !bounds.isEmpty {
            loggedFirstLayout = true
            PerfLog.mark("canvas: first layout")
        }
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
        guard session != nil, let viewport else { return }
        let scale = viewport.effectiveScale(imageSize: displaySize, viewSize: bounds.size)
        if scale != lastScale || viewport.offset != lastOffset {
            lastScale = scale
            lastOffset = viewport.offset
            needsDisplay = true
        }
    }

    private func invalidate(imageRect: CGRect) {
        guard session != nil, let viewport else { return }
        let display = displaySize
        let scale = viewport.effectiveScale(imageSize: display, viewSize: bounds.size)
        let origin = CGPoint(
            x: bounds.width / 2
                - (viewport.offset.width + display.width / 2 + (cropRect?.minX ?? 0)) * scale,
            y: bounds.height / 2
                - (viewport.offset.height + display.height / 2 + (cropRect?.minY ?? 0)) * scale)
        var viewRect = CGRect(x: origin.x + imageRect.minX * scale,
                              y: origin.y + imageRect.minY * scale,
                              width: imageRect.width * scale,
                              height: imageRect.height * scale)
        if cropAngle != 0 {
            // The bitmap is drawn rotated about the crop center's view
            // position — dirty rects must cover the rotated placement.
            viewRect = viewRect.applying(rotationAboutCropCenter(scale: scale))
        }
        setNeedsDisplay(viewRect.insetBy(dx: -2, dy: -2).intersection(bounds))
    }

    /// View-space rotation the draw pass applies to the bitmap (identity
    /// when no rotated crop is shown). CGRect.applying takes the bounding
    /// box, which is exactly what dirty rects need.
    private func rotationAboutCropCenter(scale: CGFloat) -> CGAffineTransform {
        guard let viewport, cropAngle != 0 else { return .identity }
        let cx = bounds.width / 2 - viewport.offset.width * scale
        let cy = bounds.height / 2 - viewport.offset.height * scale
        return CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: -CGFloat(cropAngle) * .pi / 180)
            .translatedBy(x: -cx, y: -cy)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(dirtyRect)
        guard let session, let viewport else { return }
        let imageSize = session.nominalSize
        let display = displaySize
        let scale = viewport.effectiveScale(imageSize: display, viewSize: bounds.size)
        // View position of the bitmap's pixel (0,0) in the displayed
        // (possibly cropped) coordinate space — same math as
        // TonedImagePaneNSView so the panes never drift apart.
        let originX = bounds.width / 2
            - (viewport.offset.width + display.width / 2 + (cropRect?.minX ?? 0)) * scale
        let originY = bounds.height / 2
            - (viewport.offset.height + display.height / 2 + (cropRect?.minY ?? 0)) * scale
        ctx.interpolationQuality = scale >= 2 ? .none : .low
        let drawImage: ((CGImage?) -> Void) -> Void = self.showDepth
            ? session.withDepthDisplayCGImage
            : session.withDisplayCGImage
        drawImage { cg in
            guard let cg else { return }
            ctx.saveGState()
            if cropRect != nil {
                // Clip to the displayed crop region: the bitmap extends past
                // it (and rotated spill would render "whole image, tilted").
                ctx.clip(to: CGRect(
                    x: bounds.width / 2
                        - (viewport.offset.width + display.width / 2) * scale,
                    y: bounds.height / 2
                        - (viewport.offset.height + display.height / 2) * scale,
                    width: display.width * scale,
                    height: display.height * scale))
                if cropAngle != 0 {
                    ctx.concatenate(rotationAboutCropCenter(scale: scale))
                }
            }
            // draw(_:in:) is bottom-up; re-flip within our flipped coordinates.
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            let drawRect = CGRect(x: originX,
                                  y: bounds.height - originY - imageSize.height * scale,
                                  width: imageSize.width * scale,
                                  height: imageSize.height * scale)
            // Count the first draw that actually puts pixels on screen: an
            // early pass at zero bounds draws an empty rect in no time and
            // would report a latency the user never experienced.
            if loggedFirstDraw || drawRect.isEmpty || dirtyRect.isEmpty {
                ctx.draw(cg, in: drawRect)
            } else {
                loggedFirstDraw = true
                PerfLog.span("canvas: first ctx.draw \(cg.width)×\(cg.height)"
                             + " → \(Int(dirtyRect.width))×\(Int(dirtyRect.height)) pt") {
                    ctx.draw(cg, in: drawRect)
                }
                PerfLog.mark("canvas: first draw done")
            }
            ctx.restoreGState()
        }
    }
}

struct RetouchCanvas: NSViewRepresentable {
    let session: RetouchSession
    let viewport: ViewportState
    var tone = ToneSettings()
    var showDepth = false
    var cropRect: CGRect? = nil
    var cropAngle: Double = 0

    func makeNSView(context: Context) -> RetouchCanvasNSView {
        PerfLog.mark("canvas: makeNSView entered")
        let view = RetouchCanvasNSView()
        // Without this, macOS silently ignores Core Image layer filters.
        view.layerUsesCoreImageFilters = true
        view.viewport = viewport
        view.attach(session: session)
        view.showDepth = showDepth
        view.cropRect = cropRect
        view.cropAngle = cropAngle
        // The depth map is a data visualization — never tone it.
        view.applyTone(showDepth ? ToneSettings() : tone)
        PerfLog.mark("canvas: makeNSView returned")
        return view
    }

    func updateNSView(_ view: RetouchCanvasNSView, context: Context) {
        view.viewport = viewport
        view.attach(session: session)
        view.showDepth = showDepth
        view.cropRect = cropRect
        view.cropAngle = cropAngle
        view.applyTone(showDepth ? ToneSettings() : tone)
        view.viewportDidUpdate()
    }
}

struct RetouchOverlay: NSViewRepresentable {
    let viewport: ViewportState
    /// Displayed (crop-space) size — the shared pan/zoom coordinate space.
    let imageSize: CGSize
    let session: RetouchSession
    var cropOrigin: CGPoint = .zero
    var cropAngle: Double = 0
    /// Drag mode (⌘ held) — the panes hide the brush circle while it is on.
    @Binding var panModifierHeld: Bool

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
        view.onToggleDMap = { [weak session] in session?.toggleDMapLayer() }
        // R follows the base/eraser whichever algorithm fused it (it toggled
        // the DMap layer historically, when DMap was the only primary).
        view.onToggleResult = { [weak session] in session?.toggleResultLayer() }
        return view
    }

    func updateNSView(_ view: RetouchEventView, context: Context) {
        view.viewport = viewport
        view.imageSize = imageSize
        view.cropOrigin = cropOrigin
        view.cropAngle = cropAngle
        // Reassigned rather than set once in makeNSView: the binding is a
        // value, and only the current one writes to live state.
        let held = $panModifierHeld
        view.onPanModifier = { held.wrappedValue = $0 }
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
        // 6, not the old 2: with the full-width track (labelsHidden below)
        // the label row sits directly over the slider, and 2pt read tight —
        // the Qt shell's style pads its slider control internally.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .infoTip(help)
                Spacer()
                Text(displayString)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(id.map { "\($0).value" } ?? "")
            }
            // The grouped Form treats a bare Slider as a labeled control and
            // pins it to the form's shared content-column guide — half a row.
            // labelsHidden() opts it out, so the track spans the full row
            // (label above, slider below), matching the Qt shell's layout.
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
            }
            .labelsHidden()
            .accessibilityIdentifier(id ?? "")
            .accessibilityLabel(label)
            .accessibilityValue(displayString)
        }
        // The (i) icon alone carries the tooltip (its .infoTip above) — a
        // row-wide .help would double up with it, and the Qt shell already
        // scopes the tip to the icon so hovering the slider doesn't
        // surprise the user with a popup.
    }
}

/// The sidebar/preview divider's grab strip: drags like HSplitView's
/// divider (resize cursor, absolute tracking from the grab point, hit area
/// wider than the visible hairline), writing the width through the binding
/// so it persists (AppModel.sidebarWidth). Positioned over the hairline by
/// the split container's overlay — see the z-order comment there.
private struct SidebarSplitter: View {
    @Binding var width: Double
    /// The sidebar's draggable range — the floor matches the Qt shell's
    /// fixed width; the ceiling is the old HSplitView maxWidth.
    static let range: ClosedRange<Double> = 280...360
    /// Grabbable a few points either side of the hairline, like a real
    /// split view divider.
    static let grabWidth: CGFloat = 9

    var body: some View {
        SplitterDragOverlay(
            startWidth: { width },
            resize: { width = min(max($0, Self.range.lowerBound),
                                  Self.range.upperBound) })
            .frame(width: Self.grabWidth)
    }
}

/// AppKit event layer for the splitter: SwiftUI's DragGesture loses the
/// resize cursor mid-drag; an NSView holds it with cursor push/pop and
/// tracks in window coordinates.
private struct SplitterDragOverlay: NSViewRepresentable {
    /// Reads the sidebar width at mouse-down; the drag applies its total
    /// delta to that anchor, so a drag clamped at a bound doesn't wind up.
    let startWidth: () -> Double
    let resize: (Double) -> Void

    final class SplitterEventView: NSView {
        var startWidth: () -> Double = { 0 }
        var resize: (Double) -> Void = { _ in }
        private var dragAnchor: (x: CGFloat, width: Double)?

        // A tracking area re-asserting the cursor on EVERY move, not a
        // cursor rect: addCursorRect fires only on entering the rect, and
        // approaching from the preview side the hosting view's own
        // tracking re-set the arrow immediately after — the resize cursor
        // appeared only when entering from the sidebar side (same failure
        // mode CropOverlayNSView documents).
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited,
                          .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseMoved(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            dragAnchor = (event.locationInWindow.x, startWidth())
            NSCursor.resizeLeftRight.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let anchor = dragAnchor else { return }
            resize(anchor.width + Double(event.locationInWindow.x - anchor.x))
        }

        override func mouseUp(with event: NSEvent) {
            dragAnchor = nil
            NSCursor.pop()
        }
    }

    func makeNSView(context: Context) -> SplitterEventView {
        let view = SplitterEventView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityIdentifier("sidebar.splitter")
        view.setAccessibilityLabel("Sidebar width")
        return view
    }

    func updateNSView(_ view: SplitterEventView, context: Context) {
        view.startWidth = startWidth
        view.resize = resize
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
        Text(UIStrings.cropHeader)
            .font(.headline)
        HStack {
            Picker(UIStrings.aspectRatioLabel, selection: $model.cropAspect) {
                ForEach(AppModel.CropAspect.allCases, id: \.self) { aspect in
                    Text(aspect.displayName).tag(aspect)
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
            .help(UIStrings.swapCropOrientationTip)
        }
        HStack {
            Button(UIStrings.accept) { model.acceptCrop() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("edit.crop-accept")
            Button(UIStrings.cancel) { model.cancelCrop() }
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
