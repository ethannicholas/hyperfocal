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

    onClosing: function(close) {
        // The native unsaved-work gate, through the same message-box
        // path as every other confirm (synchronous, full-size, icon).
        if (Shell.hasUnsavedWork && !Shell.confirmQuit())
            close.accepted = false
    }

    menuBar: MenuBar {
        Menu {
            title: "File"
            Action {
                text: "New Project…"
                shortcut: StandardKey.New
                // Confirm before the picker, like native; the chosen
                // folder REPLACES the project (Add Stack Folder adds).
                onTriggered: {
                    if (Shell.confirmNewProject())
                        newProjectDialog.open()
                }
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
                onTriggered: {
                    saveProjectDialog.selectedFile =
                        "file:///" + Shell.suggestedProjectName()
                    saveProjectDialog.open()
                }
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
                onTriggered: Shell.exportAnimationInteractive()
            }
        }
        Menu {
            title: "Edit"
            Action {
                text: "Crop…"
                shortcut: "C"
                enabled: Shell.canCrop && !Shell.cropMode
                onTriggered: Shell.beginCrop()
            }
            Action {
                text: "Swap Crop Orientation"
                shortcut: "X"
                enabled: Shell.cropMode
                onTriggered: Shell.toggleCropOrientation()
            }
            Action {
                text: "Accept Crop"
                enabled: Shell.cropMode
                onTriggered: Shell.acceptCrop()
            }
            Action {
                text: "Cancel Crop"
                enabled: Shell.cropMode
                onTriggered: Shell.cancelCrop()
            }
            MenuSeparator {}
            Action {
                text: "Settings…"
                shortcut: StandardKey.Preferences
                onTriggered: settingsDialog.open()
            }
            MenuSeparator {}
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
    // Zoom: ⌘+/⌘−/⌘0 (Ctrl elsewhere), acting on the shared viewport.
    Shortcut {
        sequences: [StandardKey.ZoomIn]
        onActivated: outputPane.item.zoomBy(1.25)
    }
    Shortcut {
        sequences: [StandardKey.ZoomOut]
        onActivated: outputPane.item.zoomBy(1 / 1.25)
    }
    Shortcut {
        sequence: "Ctrl+0"
        onActivated: outputPane.item.fit()
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

    // The native Settings window's pipeline toggles (labels match
    // SettingsView.swift; GPU gated on an engine existing).
    Dialog {
        id: settingsDialog
        title: "Settings"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Close
        onOpened: {
            orderToggle.checked = Shell.boolSetting("order-by-capture")
            alignToggle.checked = Shell.boolSetting("align")
            normalizeToggle.checked = Shell.boolSetting("normalize-exposure")
            gpuToggle.checked = Shell.boolSetting("gpu")
            diskToggle.checked = Shell.boolSetting("disk-cache")
        }
        ColumnLayout {
            spacing: 8
            CheckBox {
                id: orderToggle
                text: "Order frames by capture time"
                onToggled: Shell.setBoolSetting("order-by-capture", checked)
            }
            CheckBox {
                id: alignToggle
                text: "Align frames"
                onToggled: Shell.setBoolSetting("align", checked)
            }
            CheckBox {
                id: normalizeToggle
                text: "Even out exposure"
                onToggled: Shell.setBoolSetting("normalize-exposure", checked)
            }
            CheckBox {
                id: gpuToggle
                text: "Use GPU"
                enabled: Shell.gpuAvailable()
                onToggled: Shell.setBoolSetting("gpu", checked)
            }
            CheckBox {
                id: diskToggle
                text: "Cache frames on disk while fusing"
                onToggled: Shell.setBoolSetting("disk-cache", checked)
            }
        }
    }

    FolderDialog {
        id: openDialog
        title: "Choose a stack folder"
        onAccepted: Shell.openStack(selectedFolder)
    }

    FolderDialog {
        id: newProjectDialog
        title: "Choose a stack: a folder of frames"
        onAccepted: Shell.newProject(selectedFolder)
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



    // A pane with the tone LUT shader over its layer — the native
    // ToneFilteredPaneView's color-cube-on-layer, mirrored. The PaneItem
    // stays on top (hideSource hides its direct rendering) so it keeps
    // receiving wheel/drag events.
    component TonedPane: ColumnLayout {
        id: toned
        property bool inputSource: false
        property bool dataDisplay: false
        property string title: ""
        property string hint: ""
        readonly property PaneItem item: paneItem
        // Overlays (crop, progress) reparent here so they align exactly
        // with the image area, not the title strip.
        readonly property Item contentArea: contentAreaItem
        spacing: 0

        // Header bar ABOVE the image, the native PreviewPane header:
        // left-aligned title plus a slot for pane controls (the output
        // pane's mode picker reparents here); always present so the two
        // panes' image areas stay aligned.
        readonly property Item headerArea: headerSlot
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Math.max(26, headerSlot.implicitHeight + 4)
            color: "#242424"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 4
                spacing: 6
                Label {
                    Layout.fillWidth: true
                    text: toned.title
                    color: "#b5b5b5"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignLeft
                    elide: Text.ElideMiddle
                }
                Item {
                    id: headerSlot
                    implicitWidth: childrenRect.width
                    implicitHeight: childrenRect.height
                    Layout.alignment: Qt.AlignVCenter
                }
            }
        }
        Item {
            id: contentAreaItem
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            Rectangle { anchors.fill: parent; color: "black"; z: -1 }
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
                anchors.centerIn: parent
                text: toned.hint
                visible: toned.hint !== ""
                color: "#777777"
                font.pixelSize: 13
            }
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
            // Tone drags record one undo entry per drag; the noise
            // floor shows its live depth preview while held (both are
            // the native onEditingChanged brackets).
            onPressedChanged: {
                if (parent.sliderId.startsWith("tone."))
                    Shell.toneEditing(pressed)
                else if (parent.sliderId === "fusion.slider.noise-floor")
                    Shell.noiseFloorEditing(pressed)
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
            // macOS-style transient scrollbar: visible only while the
            // content moves or the bar is dragged, fading out after —
            // never a persistent overlay covering sidebar content.
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical: ScrollBar {
                parent: sidebarScroll
                x: sidebarScroll.width - width
                y: sidebarScroll.topPadding
                height: sidebarScroll.availableHeight
                policy: ScrollBar.AsNeeded
                opacity: active ? 0.8 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

        ColumnLayout {
            width: sidebarScroll.availableWidth
            // Stretch to the viewport when content fits, so the Export
            // button stays pinned to the bottom.
            height: Math.max(implicitHeight, sidebarScroll.availableHeight)
            spacing: 10

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
                // Bounded and independently scrollable — a big tree
                // must not shove the fusion/tone controls offscreen
                // (native bounds the stack area the same way).
                Layout.preferredHeight: Math.min(300, contentHeight)
                clip: true
                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    opacity: active ? 0.8 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
                model: Shell.stacks
                delegate: ColumnLayout {
                    id: stackDelegate
                    required property int index
                    required property var modelData
                    width: stackList.width
                    spacing: 2
                    RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    // Hand-rolled disclosure chevron (the native tree
                    // avoids DisclosureGroup for accessibility too).
                    ToolButton {
                        text: stackDelegate.modelData.expanded ? "▾" : "▸"
                        font.pixelSize: 10
                        implicitWidth: 22
                        implicitHeight: 22
                        onClicked: Shell.setStackExpanded(
                            stackDelegate.index,
                            !stackDelegate.modelData.expanded)
                    }
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
                        text: stackDelegate.modelData.frameCount
                        color: "#8a8a8a"
                        font.pixelSize: 11
                    }
                    }
                    // Nested frame rows while disclosed; dimmed and
                    // inert when the stack is disabled, like native.
                    Repeater {
                        model: stackDelegate.modelData.expanded
                               ? stackDelegate.modelData.frames : []
                        delegate: RowLayout {
                            required property int index
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.leftMargin: 28
                            spacing: 6
                            opacity: stackDelegate.modelData.enabled ? 1 : 0.4
                            enabled: stackDelegate.modelData.enabled
                            CheckBox {
                                checked: modelData.included
                                enabled: !Shell.isRunning
                                onToggled: Shell.setStackFrameIncluded(
                                    stackDelegate.index, index, checked)
                            }
                            Label {
                                text: modelData.name
                                color: modelData.included ? "#d5d5d5"
                                                          : "#777777"
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }
                            Label {
                                text: "⚠"
                                visible: modelData.issue !== ""
                                color: "#e0c04a"
                                ToolTip.visible: nestedIssueHover.hovered
                                ToolTip.text: modelData.issue
                                HoverHandler { id: nestedIssueHover }
                            }
                        }
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
            // Native empty state: hint + Open Folder…, under the
            // Stack label, only while no stack is open.
            Label {
                Layout.fillWidth: true
                visible: stackList.count === 0 && frameList.count === 0
                text: "Drop a folder of frames here, or:"
                color: "#8a8a8a"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
            Button {
                Layout.fillWidth: true
                visible: stackList.count === 0 && frameList.count === 0
                text: "Open Folder…"
                enabled: !Shell.isRunning
                onClicked: openDialog.open()
            }
            ListView {
                id: frameList
                // Single-stack projects list frames flat; with several
                // stacks the tree's nested rows take over, like native.
                visible: stackList.count <= 1
                Layout.fillWidth: true
                Layout.preferredHeight: visible
                    ? Math.min(300, contentHeight) : 0
                clip: true
                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    opacity: active ? 0.8 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
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
                text: "Crop…"
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
                    // Equal split regardless of title length (implicit
                    // widths must not skew the layout).
                    Layout.preferredWidth: 1
                    title: Shell.inputTitle !== "" ? Shell.inputTitle
                                                   : "Input"
                    hint: Shell.hasInput ? ""
                        : Shell.frames.length === 0
                            ? "Open a stack to begin"
                            : "Select a frame in the Stack list"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
                TonedPane {
                    id: outputPane
                    Layout.preferredWidth: 1
                    title: "Output"
                    dataDisplay: Shell.displayIsData
                    hint: Shell.hasDisplay ? ""
                        : Shell.canFuse ? "Press “Fuse Stack”" : "No output yet"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Segmented mode picker in the pane header, the
                    // native output.mode placement.
                    Row {
                        parent: outputPane.headerArea
                        spacing: 1
                        Button {
                            text: "Result"
                            checkable: true
                            autoExclusive: true
                            checked: !Shell.depthMode
                            onClicked: Shell.depthMode = false
                            implicitWidth: 64
                            implicitHeight: 22
                            font.pixelSize: 11
                        }
                        Button {
                            text: "Depth"
                            checkable: true
                            autoExclusive: true
                            checked: Shell.depthMode
                            onClicked: Shell.depthMode = true
                            implicitWidth: 64
                            implicitHeight: 22
                            font.pixelSize: 11
                        }
                    }
                    CropOverlay {
                        parent: outputPane.contentArea
                        anchors.fill: parent
                        pane: outputPane.item
                        visible: Shell.cropMode
                    }
                    // The native progress overlay: bar + stage + ETA +
                    // Cancel in a rounded card over the output pane.
                    Rectangle {
                        parent: outputPane.contentArea
                        visible: Shell.isRunning
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.margins: 12
                        anchors.bottomMargin: 12
                        width: parent.width - 24
                        height: progressColumn.implicitHeight + 20
                        radius: 8
                        color: "#e0282828"
                        ColumnLayout {
                            id: progressColumn
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6
                            ProgressBar {
                                Layout.fillWidth: true
                                value: Shell.stageFraction
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Label {
                                    text: Shell.stageText
                                    color: "#b5b5b5"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Label {
                                    text: Shell.stageEta
                                    visible: text !== ""
                                    color: "#8a8a8a"
                                    font.pixelSize: 12
                                }
                                Button {
                                    text: "Cancel"
                                    font.pixelSize: 11
                                    onClicked: Shell.cancelFuse()
                                }
                            }
                        }
                    }
                }
            }

            // Zoom bar along the bottom, native placement and order:
            // Zoom: [Fit/N% ⌵] [−] [+], flat so it reads as a toolbar.
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 6
                Item { Layout.fillWidth: true }
                Label { text: "Zoom:"; color: "#b5b5b5"; font.pixelSize: 12 }
                ToolButton {
                    id: zoomMenuButton
                    text: (outputPane.item.fitted ? "Fit"
                          : Math.round(outputPane.item.displayScale * 100)
                            + "%") + "  ⌵"
                    font.pixelSize: 12
                    onClicked: zoomMenu.open()
                    Menu {
                        id: zoomMenu
                        y: -implicitHeight - 4
                        MenuItem { text: "Fit"; onTriggered: outputPane.item.fit() }
                        MenuItem { text: "25%"; onTriggered: outputPane.item.setAbsoluteScale(0.25) }
                        MenuItem { text: "50%"; onTriggered: outputPane.item.setAbsoluteScale(0.5) }
                        MenuItem { text: "100%"; onTriggered: outputPane.item.setAbsoluteScale(1) }
                        MenuItem { text: "200%"; onTriggered: outputPane.item.setAbsoluteScale(2) }
                        MenuItem { text: "400%"; onTriggered: outputPane.item.setAbsoluteScale(4) }
                    }
                }
                ToolButton {
                    icon.name: "zoom-out"
                    icon.width: 16
                    icon.height: 16
                    onClicked: outputPane.item.zoomBy(1 / 1.25)
                }
                ToolButton {
                    icon.name: "zoom-in"
                    icon.width: 16
                    icon.height: 16
                    onClicked: outputPane.item.zoomBy(1.25)
                }
                Item { Layout.fillWidth: true }
            }
        }
    }
}
