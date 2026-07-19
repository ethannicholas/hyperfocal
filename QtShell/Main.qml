// Phase 2 shell: sidebar (stack list, fusion sliders, fuse, tone, export)
// + output pane with Result/Depth toggle — mirroring the native app's
// layout so the two can be compared side-by-side on one machine. Still
// deliberately spartan; it proves the bridge surface, not the chrome.
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Hyperfocal

ApplicationWindow {
    id: window
    width: 1280
    height: 800
    visible: true
    title: "Hyperfocal (Qt shell — dev)"
    color: "#1b1b1b"

    // One viewport across both panes, the native shells' shared
    // ViewportState: a gesture on either pane lands on both.
    Component.onCompleted: {
        inputPane.item.syncPane = outputPane.item
        outputPane.item.syncPane = inputPane.item
        // The selftest's zoom-cycle journey finds the pane by this name.
        outputPane.item.objectName = "outputPaneItem"
    }

    Connections {
        target: Shell
        function onChanged() {
            outputPane.item.refresh()
            inputPane.item.refresh()
        }
    }

    // The native ⌘Z family (platform-correct sequences via StandardKey);
    // menu entries with the mode-scoped titles arrive with the menu bar.
    Shortcut {
        sequences: [StandardKey.Undo]
        enabled: Shell.canUndo
        onActivated: Shell.undo()
    }
    Shortcut {
        sequences: [StandardKey.Redo]
        enabled: Shell.canRedo
        onActivated: Shell.redo()
    }

    FolderDialog {
        id: openDialog
        title: "Choose a stack folder"
        onAccepted: Shell.openStack(selectedFolder)
    }

    FileDialog {
        id: exportDialog
        title: "Export result"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "tif"
        nameFilters: ["TIFF (*.tif)"]
        onAccepted: Shell.exportTo(selectedFile)
    }

    // A pane with the tone LUT shader over its layer — the native
    // ToneFilteredPaneView's color-cube-on-layer, mirrored. The PaneItem
    // stays on top (hideSource hides its direct rendering) so it keeps
    // receiving wheel/drag events.
    component TonedPane: Pane {
        id: toned
        property bool inputSource: false
        property bool dataDisplay: false
        property string title: ""
        readonly property PaneItem item: paneItem
        padding: 0
        background: Rectangle { color: "black" }

        ShaderEffect {
            anchors.fill: parent
            property variant source: ShaderEffectSource {
                sourceItem: paneItem
                hideSource: true
                live: true
            }
            property variant lut: lutImage
            property real lutEnabled: toned.dataDisplay ? 0.0 : 1.0
            fragmentShader: "qrc:/lut.frag.qsb"
        }
        PaneItem {
            id: paneItem
            anchors.fill: parent
            input: toned.inputSource
        }
        Label {
            text: toned.title
            visible: text !== ""
            color: "#d5d5d5"
            font.pixelSize: 12
            padding: 4
            background: Rectangle { color: "#c0000000"; radius: 3 }
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: 6
        }
    }

    component SidebarSlider: ColumnLayout {
        required property string sliderId
        required property string label
        required property real from
        required property real to
        property string format: "%1"
        property int decimals: 2
        spacing: 2
        Layout.fillWidth: true
        RowLayout {
            Layout.fillWidth: true
            Label { text: label; color: "#b5b5b5"; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            Label {
                text: format.arg(control.value.toFixed(decimals))
                color: "#8a8a8a"
                font.pixelSize: 12
                font.family: "Menlo"
            }
        }
        Slider {
            id: control
            Layout.fillWidth: true
            from: parent.from
            to: parent.to
            value: Shell.slider(parent.sliderId)
            onMoved: Shell.setSlider(parent.sliderId, value)
            // Tone drags record one undo entry per drag (the native
            // onEditingChanged bracket); fusion sliders aren't undoable.
            onPressedChanged: {
                if (parent.sliderId.startsWith("tone."))
                    Shell.toneEditing(pressed)
            }
            // Re-read on model changes (reset, project load).
            Connections {
                target: Shell
                function onChanged() {
                    if (!control.pressed)
                        control.value = Shell.slider(control.parent.sliderId)
                }
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Sidebar — scrolls when its sections outgrow the window.
        ScrollView {
            id: sidebarScroll
            Layout.preferredWidth: 280
            Layout.maximumWidth: 280
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            padding: 10

        ColumnLayout {
            width: sidebarScroll.availableWidth
            // Stretch to the viewport when content fits, so the Export
            // button stays pinned to the bottom.
            height: Math.max(implicitHeight, sidebarScroll.availableHeight)
            spacing: 10

            Button {
                Layout.fillWidth: true
                text: "Open Stack…"
                enabled: !Shell.isRunning
                onClicked: openDialog.open()
            }

            // Stack tree (flat mirror): shown once a second stack exists,
            // like the native sidebar. Row click selects (stash/install);
            // the checkbox is the batch-fuse opt-in.
            Label {
                text: "Stacks"
                visible: stackList.count > 1
                color: "#d5d5d5"
                font.bold: true
            }
            ListView {
                id: stackList
                visible: count > 1
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(160, contentHeight)
                clip: true
                model: Shell.stacks
                delegate: RowLayout {
                    required property int index
                    required property var modelData
                    width: stackList.width
                    spacing: 6
                    CheckBox {
                        checked: modelData.enabled
                        enabled: !Shell.isRunning
                        onToggled: Shell.setStackEnabled(index, checked)
                    }
                    Label {
                        text: modelData.name
                        color: index === Shell.selectedStack ? "#ffffff"
                                                             : "#a5a5a5"
                        font.bold: index === Shell.selectedStack
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        TapHandler {
                            enabled: !Shell.isRunning
                            onTapped: Shell.selectStack(index)
                        }
                    }
                    Label {
                        // Load-time frame-order warning badge.
                        text: "△"
                        visible: modelData.orderWarning !== ""
                        color: "#e0c04a"
                        ToolTip.visible: orderHover.hovered
                        ToolTip.text: modelData.orderWarning
                        HoverHandler { id: orderHover }
                    }
                    Label {
                        // The native tree's status glyph, textified:
                        // fusing / fused / failed (hover = message).
                        text: modelData.status === 1 ? "…"
                            : modelData.status === 2 ? "✓"
                            : modelData.status === 3 ? "⚠" : ""
                        color: modelData.status === 3 ? "#e0c04a" : "#6fbf73"
                        ToolTip.visible: modelData.status === 3 && hover.hovered
                        ToolTip.text: modelData.failure
                        HoverHandler { id: hover }
                    }
                    Label {
                        text: modelData.frameCount
                        color: "#8a8a8a"
                        font.pixelSize: 11
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: "Stack"; color: "#d5d5d5"; font.bold: true }
                Label {
                    // "N of M" included count, the native stack.count.
                    text: {
                        var n = 0
                        for (var i = 0; i < Shell.frames.length; ++i)
                            if (Shell.frames[i].included) ++n
                        return n + " of " + Shell.frames.length
                    }
                    visible: Shell.frames.length > 0
                    color: "#8a8a8a"
                    font.pixelSize: 11
                }
                Item { Layout.fillWidth: true }
                Button {
                    text: "All"
                    visible: frameList.count > 0
                    enabled: !Shell.isRunning
                    flat: true
                    font.pixelSize: 11
                    onClicked: Shell.setAllFramesIncluded(true)
                }
                Button {
                    text: "None"
                    visible: frameList.count > 0
                    enabled: !Shell.isRunning
                    flat: true
                    font.pixelSize: 11
                    onClicked: Shell.setAllFramesIncluded(false)
                }
            }
            ListView {
                id: frameList
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(240, contentHeight)
                clip: true
                model: Shell.frames
                delegate: RowLayout {
                    width: frameList.width
                    spacing: 6
                    CheckBox {
                        checked: modelData.included
                        enabled: !Shell.isRunning
                        onToggled: Shell.setFrameIncluded(index, checked)
                    }
                    Label {
                        // Click selects the frame — the input pane follows.
                        text: modelData.name
                        color: modelData.included ? "#d5d5d5" : "#777777"
                        font.bold: index === Shell.selectedFrame
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        TapHandler { onTapped: Shell.selectFrame(index) }
                    }
                    Label {
                        // Fuse-time issue badge (misfire/misalignment).
                        text: "⚠"
                        visible: modelData.issue !== ""
                        color: "#e0c04a"
                        ToolTip.visible: issueHover.hovered
                        ToolTip.text: modelData.issue
                        HoverHandler { id: issueHover }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label { text: "Fusion"; color: "#d5d5d5"; font.bold: true }
                Item { Layout.fillWidth: true }
                Button {
                    text: "Reset"
                    visible: !Shell.fusionDefault
                    enabled: !Shell.isRunning
                    flat: true
                    font.pixelSize: 11
                    onClicked: Shell.resetFusion()
                }
            }
            SidebarSlider {
                sliderId: "fusion.slider.sharpness"
                label: "Sharpness σ"; from: 1; to: 16; format: "%1 px"
                enabled: !Shell.isRunning
            }
            SidebarSlider {
                sliderId: "fusion.slider.noise-floor"
                label: "Noise floor"; from: 0.01; to: 1
                enabled: !Shell.isRunning
            }
            SidebarSlider {
                sliderId: "fusion.slider.median-radius"
                label: "Median radius"; from: 0; to: 32; format: "%1 px"
                enabled: !Shell.isRunning
            }
            SidebarSlider {
                sliderId: "fusion.slider.blend-radius"
                label: "Blend radius"; from: 0.75; to: 4
                enabled: !Shell.isRunning
            }
            Button {
                Layout.fillWidth: true
                text: "Fuse Stack"
                enabled: Shell.canFuse
                highlighted: true
                onClicked: Shell.fuse()
            }
            Button {
                Layout.fillWidth: true
                visible: stackList.count > 1
                text: "Fuse " + Shell.pendingStackCount + " Stacks"
                enabled: Shell.pendingStackCount > 0 && !Shell.isRunning
                onClicked: Shell.fuseEnabledStacks()
            }
            RowLayout {
                Layout.fillWidth: true
                visible: Shell.isRunning
                spacing: 6
                ProgressBar {
                    Layout.fillWidth: true
                    value: Shell.stageFraction
                }
                Button {
                    text: "Cancel"
                    font.pixelSize: 11
                    onClicked: Shell.cancelFuse()
                }
            }
            Label {
                Layout.fillWidth: true
                visible: Shell.isRunning
                text: Shell.stageText
                color: "#b5b5b5"
                font.pixelSize: 12
                elide: Text.ElideRight
            }

            RowLayout {
                Layout.fillWidth: true
                Label { text: "Tone"; color: "#d5d5d5"; font.bold: true }
                Item { Layout.fillWidth: true }
                Button {
                    text: "Reset"
                    visible: !Shell.toneNeutral
                    flat: true
                    font.pixelSize: 11
                    onClicked: Shell.resetTone()
                }
            }
            SidebarSlider {
                sliderId: "tone.slider.exposure"
                label: "Exposure"; from: -5; to: 5; format: "%1 EV"
            }
            SidebarSlider {
                sliderId: "tone.slider.contrast"
                label: "Contrast"; from: -100; to: 100; decimals: 0
            }
            SidebarSlider {
                sliderId: "tone.slider.highlights"
                label: "Highlights"; from: -100; to: 100; decimals: 0
            }
            SidebarSlider {
                sliderId: "tone.slider.shadows"
                label: "Shadows"; from: -100; to: 100; decimals: 0
            }
            SidebarSlider {
                sliderId: "tone.slider.whites"
                label: "Whites"; from: -100; to: 100; decimals: 0
            }
            SidebarSlider {
                sliderId: "tone.slider.blacks"
                label: "Blacks"; from: -100; to: 100; decimals: 0
            }

            Label { text: "Crop"; color: "#d5d5d5"; font.bold: true }
            // Numeric stand-in for the native drag overlay (result-canvas
            // px + degrees) — enough to exercise the presentation and
            // export until the Qt shell grows real handles.
            GridLayout {
                columns: 4
                columnSpacing: 6
                Layout.fillWidth: true
                component CropField: TextField {
                    Layout.fillWidth: true
                    font.pixelSize: 12
                    validator: DoubleValidator {}
                }
                CropField { id: cropX; placeholderText: "x" }
                CropField { id: cropY; placeholderText: "y" }
                CropField { id: cropW; placeholderText: "w" }
                CropField { id: cropH; placeholderText: "h" }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Label { text: "Angle"; color: "#b5b5b5"; font.pixelSize: 12 }
                Slider {
                    id: cropAngle
                    from: -45; to: 45; value: 0
                    Layout.fillWidth: true
                }
                Label {
                    text: cropAngle.value.toFixed(1) + "°"
                    color: "#8a8a8a"
                    font.pixelSize: 12
                    font.family: "Menlo"
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "Apply Crop"
                    Layout.fillWidth: true
                    enabled: !Shell.isRunning
                    onClicked: Shell.setCrop(Number(cropX.text), Number(cropY.text),
                                             Number(cropW.text), Number(cropH.text),
                                             cropAngle.value)
                }
                Button {
                    text: "Clear"
                    enabled: !Shell.isRunning
                    onClicked: Shell.setCrop(0, 0, 0, 0, 0)
                }
            }
            Label {
                Layout.fillWidth: true
                visible: Shell.displayCrop.width > 0
                text: "Presenting " + Shell.displayCrop.width + "×"
                      + Shell.displayCrop.height + " @ ("
                      + Shell.displayCrop.x + ", " + Shell.displayCrop.y + ")"
                      + (Shell.displayCropAngle !== 0
                         ? ", " + Shell.displayCropAngle + "°" : "")
                color: "#8a8a8a"
                font.pixelSize: 11
                elide: Text.ElideRight
            }

            Item { Layout.fillHeight: true }

            Button {
                Layout.fillWidth: true
                text: "Export…"
                enabled: !Shell.isRunning
                onClicked: exportDialog.open()
            }
        }
        }

        // Preview side
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 6
                Item { Layout.fillWidth: true }
                ButtonGroup { id: modeGroup }
                RadioButton {
                    text: "Result"
                    ButtonGroup.group: modeGroup
                    checked: !Shell.depthMode
                    onClicked: Shell.depthMode = false
                }
                RadioButton {
                    text: "Depth"
                    ButtonGroup.group: modeGroup
                    checked: Shell.depthMode
                    onClicked: Shell.depthMode = true
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 1

                Image {
                    id: lutImage
                    visible: false
                    source: "image://hflut/" + Shell.lutEpoch
                    smooth: true
                }

                // The input pane appears once a frame preview exists,
                // beside the output — the native fusionPreviewPanes HStack.
                // Both panes share one viewport (syncPane) and the same
                // tone LUT; the input is toned too, like the native app.
                TonedPane {
                    id: inputPane
                    visible: Shell.hasInput
                    inputSource: true
                    title: Shell.inputTitle
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
                TonedPane {
                    id: outputPane
                    dataDisplay: Shell.displayIsData
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
            }
        }
    }
}
