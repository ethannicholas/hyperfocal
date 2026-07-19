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
    // Project name + dirty marker, the native titlebar behavior.
    title: {
        var name = "Hyperfocal"
        if (Shell.projectPath !== "") {
            var parts = Shell.projectPath.split("/")
            name = parts[parts.length - 1].replace(/\.hyperfocal$/, "")
        }
        return name + (Shell.hasUnsavedWork ? " — Edited" : "")
    }
    color: "#1b1b1b"

    property bool quitApproved: false
    onClosing: function(close) {
        // The native unsaved-work gate, through the same confirm shape.
        if (Shell.hasUnsavedWork && !quitApproved) {
            close.accepted = false
            quitDialog.open()
        }
    }

    menuBar: MenuBar {
        Menu {
            title: "File"
            Action {
                text: "New Project…"
                shortcut: StandardKey.New
                onTriggered: openDialog.open()
            }
            Action {
                text: "Open Project…"
                shortcut: StandardKey.Open
                onTriggered: openProjectDialog.open()
            }
            Action {
                text: "Add Stack Folder…"
                shortcut: "Ctrl+Shift+N"
                onTriggered: openDialog.open()
            }
            MenuSeparator {}
            Action {
                text: "Close Stack"
                enabled: !Shell.isRunning && Shell.stacks.length > 0
                onTriggered: Shell.closeStack()
            }
            Action {
                text: "Close Project"
                enabled: !Shell.isRunning && Shell.stacks.length > 0
                onTriggered: Shell.closeProject()
            }
            MenuSeparator {}
            Action {
                text: "Save Project"
                shortcut: StandardKey.Save
                enabled: !Shell.isRunning
                onTriggered: {
                    if (!Shell.saveProject(""))
                        saveProjectDialog.open()
                }
            }
            Action {
                text: "Save Project As…"
                shortcut: "Ctrl+Shift+S"
                enabled: !Shell.isRunning
                onTriggered: saveProjectDialog.open()
            }
            MenuSeparator {}
            Action {
                text: Shell.depthMode ? "Export Depth Map…" : "Export Result…"
                shortcut: "Ctrl+E"
                enabled: !Shell.isRunning && Shell.hasDisplay
                onTriggered: Shell.exportInteractive()
            }
            Action {
                text: "Export All Fused…"
                enabled: !Shell.isRunning && Shell.fusedStackCount > 1
                onTriggered: exportAllDialog.open()
            }
            Action {
                text: "Export Aligned Frames…"
                shortcut: "Ctrl+Shift+E"
                enabled: !Shell.isRunning && Shell.canExportAligned
                onTriggered: exportAlignedDialog.open()
            }
            Action {
                text: "Export Rocking Animation…"
                enabled: !Shell.isRunning && Shell.canAnimate
                onTriggered: animationOptionsDialog.open()
            }
        }
        Menu {
            title: "Edit"
            Action {
                text: Shell.undoTitle
                shortcut: StandardKey.Undo
                enabled: Shell.canUndo
                onTriggered: Shell.undo()
            }
            Action {
                text: Shell.redoTitle
                shortcut: StandardKey.Redo
                enabled: Shell.canRedo
                onTriggered: Shell.redo()
            }
        }
    }

    Dialog {
        id: quitDialog
        title: "Are you sure you want to quit?"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Discard | Dialog.Cancel
        Label { text: "Unsaved data will be lost." }
        onDiscarded: {
            window.quitApproved = true
            quitDialog.close()
            window.close()
        }
    }

    FileDialog {
        id: openProjectDialog
        title: "Open a project"
        nameFilters: ["Hyperfocal projects (*.hyperfocal)"]
        onAccepted: Shell.openStack(selectedFile)
    }

    FileDialog {
        id: saveProjectDialog
        title: "Save project"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "hyperfocal"
        nameFilters: ["Hyperfocal projects (*.hyperfocal)"]
        onAccepted: Shell.saveProject(selectedFile)
    }

    // Folders dropped anywhere on the window add stacks, like the
    // native app.
    DropArea {
        anchors.fill: parent
        z: 100
        onDropped: function(drop) {
            for (var i = 0; i < drop.urls.length; ++i)
                Shell.openStack(drop.urls[i])
        }
    }

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
        // Every bridge callback; the panes self-guard by pixel epoch, so
        // ticks that moved nothing visible cost two integer reads.
        function onTick() {
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
    // The native crop keys: C enters, X swaps orientation, Return
    // accepts, Esc cancels.
    Shortcut {
        sequence: "C"
        enabled: Shell.canCrop && !Shell.cropMode
        onActivated: Shell.beginCrop()
    }
    Shortcut {
        sequence: "X"
        enabled: Shell.cropMode
        onActivated: Shell.toggleCropOrientation()
    }
    Shortcut {
        sequence: "Return"
        enabled: Shell.cropMode
        onActivated: Shell.acceptCrop()
    }
    Shortcut {
        sequence: "Esc"
        enabled: Shell.cropMode
        onActivated: Shell.cancelCrop()
    }

    FolderDialog {
        id: openDialog
        title: "Choose a stack folder"
        onAccepted: Shell.openStack(selectedFolder)
    }

    FolderDialog {
        id: exportAllDialog
        title: "Export every fused stack to a folder"
        onAccepted: Shell.exportAll(selectedFolder)
    }

    FolderDialog {
        id: exportAlignedDialog
        title: "Export aligned frames to a folder"
        onAccepted: Shell.exportAligned(selectedFolder)
    }

    Dialog {
        id: animationOptionsDialog
        title: "Rocking animation"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok | Dialog.Cancel
        RowLayout {
            spacing: 8
            Label { text: "Strength:"; color: "#b5b5b5" }
            ComboBox {
                model: ["Subtle", "Medium", "Strong"]
                currentIndex: Math.max(0, model.indexOf(Shell.animationStrength))
                onActivated: Shell.animationStrength = currentText
            }
        }
        onAccepted: animationFileDialog.open()
    }

    FileDialog {
        id: animationFileDialog
        title: "Export rocking animation"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "mp4"
        nameFilters: ["Movie (*.mp4)", "Animated GIF (*.gif)"]
        onAccepted: Shell.exportAnimation(selectedFile)
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
        property string hint: ""
        Label {
            anchors.centerIn: parent
            text: toned.hint
            visible: toned.hint !== ""
            color: "#777777"
            font.pixelSize: 13
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
            Button {
                Layout.fillWidth: true
                text: "Crop… (C)"
                enabled: Shell.canCrop && !Shell.cropMode
                onClicked: Shell.beginCrop()
            }
            Label {
                Layout.fillWidth: true
                visible: Shell.displayCrop.width > 0
                text: "Cropped to " + Shell.displayCrop.width + "×"
                      + Shell.displayCrop.height
                      + (Shell.displayCropAngle !== 0
                         ? ", " + Shell.displayCropAngle.toFixed(1) + "°" : "")
                color: "#8a8a8a"
                font.pixelSize: 11
                elide: Text.ElideRight
            }

            Item { Layout.fillHeight: true }

            Button {
                Layout.fillWidth: true
                text: Shell.depthMode ? "Export Depth Map…" : "Export Result…"
                enabled: !Shell.isRunning && Shell.hasDisplay
                onClicked: Shell.exportInteractive()
            }
        }
        }

        // Preview side
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Crop-mode controls, the native CropControls bar.
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 6
                visible: Shell.cropMode
                spacing: 8
                Item { Layout.fillWidth: true }
                Label { text: "Aspect:"; color: "#b5b5b5" }
                ComboBox {
                    model: ["Original", "Custom", "1:1", "3:2", "5:4",
                            "4:3", "16:9"]
                    currentIndex: Math.max(0, model.indexOf(Shell.cropAspect))
                    onActivated: Shell.cropAspect = currentText
                    Layout.preferredWidth: 120
                }
                Button {
                    text: Shell.cropPortrait ? "Portrait" : "Landscape"
                    onClicked: Shell.toggleCropOrientation()
                }
                Button {
                    text: "Cancel"
                    onClicked: Shell.cancelCrop()
                }
                Button {
                    text: "Done"
                    highlighted: true
                    onClicked: Shell.acceptCrop()
                }
                Item { Layout.fillWidth: true }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 6
                visible: !Shell.cropMode
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
                    inputSource: true
                    title: Shell.inputTitle
                    hint: Shell.hasInput ? ""
                        : Shell.frames.length === 0
                            ? "Open a stack to begin"
                            : "Select a frame in the Stack list"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
                TonedPane {
                    id: outputPane
                    dataDisplay: Shell.displayIsData
                    hint: Shell.hasDisplay ? ""
                        : Shell.canFuse ? "Press “Fuse Stack”" : "No output yet"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    CropOverlay {
                        anchors.fill: parent
                        pane: outputPane.item
                        visible: Shell.cropMode
                    }
                }
            }
        }
    }
}
