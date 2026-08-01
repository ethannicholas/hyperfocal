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
    // Preferred size, clamped to the screen's *available* area — that
    // excludes the Windows taskbar / Linux panel, which a bare 1280x800
    // does not: on a short VM display the window ran under the taskbar
    // and the sidebar footer (Export) was unreachable.
    width: Math.min(1280, Screen.desktopAvailableWidth - 40)
    height: Math.min(800, Screen.desktopAvailableHeight - 40)
    // Placement is left to the window manager: it accounts for the frame
    // (an explicit y positions the *client* area, which hangs the title
    // bar off the top edge) and it already keeps windows in the work area.
    minimumWidth: Math.min(900, Screen.desktopAvailableWidth)
    minimumHeight: Math.min(560, Screen.desktopAvailableHeight)
    visible: true
    // Project name + dirty marker, the native titlebar behavior.
    title: {
        var name = "Hyperfocal"
        if (Shell.projectPath !== "") {
            var parts = Shell.projectPath.split("/")
            name = parts[parts.length - 1].replace(/\.hyperfocal$/, "")
        }
        return Shell.hasUnsavedWork ? qsTr("%1 — Edited").arg(name) : name
    }
    color: theme.window

    // Window-scoped default font: unsized control text (menus, buttons,
    // radio labels) otherwise takes the style's fallback size — Fusion's
    // is larger than the platform styles', which inflated control minimum
    // widths until the sidebar cards overflowed their 260px column and
    // clipped at the edge.
    font.pixelSize: 13

    // The chrome follows the OS light/dark appearance, live (the design
    // rule: the system setting is the source of truth — never hardcode a
    // scheme). Every chrome color routes through here; Unknown falls
    // back to dark, the shell's historical look.
    QtObject {
        id: theme
        readonly property bool dark:
            Application.styleHints.colorScheme !== Qt.Light
        readonly property color window: dark ? "#1b1b1b" : "#f2f2f2"
        // The image wells: a neutral surround for color judgment in both
        // schemes (photo-tool convention: near-black / light gray).
        readonly property color well: dark ? "black" : "#dedede"
        readonly property color textPrimary: dark ? "#d5d5d5" : "#1d1d1d"
        readonly property color textSecondary: dark ? "#b5b5b5" : "#444444"
        readonly property color textDim: dark ? "#8a8a8a" : "#6a6a6a"
        readonly property color textFaint: dark ? "#777777" : "#9e9e9e"
        readonly property color warn: dark ? "#e0c04a" : "#8a6d00"
        readonly property color ok: dark ? "#6fbf73" : "#2e7d32"
        readonly property color cardFill:
            dark ? Qt.rgba(1, 1, 1, 0.055) : Qt.rgba(0, 0, 0, 0.05)
        readonly property color cardBorder:
            dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.09)
        readonly property color headerBar: dark ? "#242424" : "#e4e4e4"
        // The cards that float over the image wells: the progress HUD, the
        // source-loading notice, the spinner badge. They follow the scheme
        // like every other surface here — light card in the light scheme,
        // dark in dark — which is what lets the ordinary text tokens above
        // read correctly on them. Pinning them dark in both schemes was a
        // bug, not a photo-tool convention: it left textSecondary (#444444
        // in the light scheme) sitting on #282828 at about 1.3:1. The alpha
        // keeps the frame underneath faintly visible, the way the Mac side's
        // .regularMaterial does.
        readonly property color overlayCard: dark ? "#e0282828" : "#e6f2f2f2"
        readonly property color overlayCardSoft: dark ? "#c0282828" : "#ccf2f2f2"
        // Tooltips sit over image content (the busiest background in the
        // app), so unlike overlayCard they're fully opaque, not translucent.
        readonly property color tooltipFill: dark ? "#3c3c3c" : "#ffffff"
        readonly property color tooltipBorder:
            dark ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(0, 0, 0, 0.16)
    }

    // The scheme as a real Controls palette so Fusion (Windows/Linux)
    // derives every control face from it; window-scoped so every control
    // inherits, and identical across the three shells.
    palette {
        window: theme.window
        windowText: theme.textPrimary
        base: theme.dark ? "#242424" : "#ffffff"
        alternateBase: theme.dark ? "#2c2c2c" : "#ececec"
        text: theme.textPrimary
        button: theme.dark ? "#3a3a3a" : "#e4e4e4"
        buttonText: theme.textPrimary
        highlight: "#3a6ea5"
        highlightedText: "#ffffff"
        // Filled/checked control faces (highlighted Buttons, checked
        // toggles): a medium blue that carries white legibly in both
        // schemes (the OS accents vary too much to trust).
        accent: "#3a6ea5"
        placeholderText: theme.textDim
        mid: theme.dark ? "#4a4a4a" : "#b0b0b0"
        dark: theme.dark ? "#666666" : "#909090"
        disabled {
            text: theme.dark ? "#6f6f6f" : "#a8a8a8"
            buttonText: theme.dark ? "#6f6f6f" : "#a8a8a8"
            windowText: theme.dark ? "#6f6f6f" : "#a8a8a8"
        }
    }

    onClosing: function(close) {
        // The native unsaved-work gate, through the same message-box
        // path as every other confirm (synchronous, full-size, icon).
        if (Shell.hasUnsavedWork && !Shell.confirmQuit())
            close.accepted = false
    }

    menuBar: MenuBar {
        Menu {
            title: qsTr("File")
            Action {
                text: Shell.uiString("newProject")
                shortcut: StandardKey.New
                enabled: !Shell.isRunning
                // Confirm before the picker, like native; the chosen
                // folder REPLACES the project (Add Stack Folder adds).
                onTriggered: {
                    if (Shell.confirmNewProject())
                        newProjectDialog.open()
                }
            }
            Action {
                text: Shell.uiString("openProject")
                shortcut: StandardKey.Open
                enabled: !Shell.isRunning
                onTriggered: openProjectDialog.open()
            }
            Action {
                text: Shell.uiString("addStackFolder")
                shortcut: "Ctrl+Shift+N"
                enabled: !Shell.isRunning
                onTriggered: openDialog.open()
            }
            MenuSeparator {}
            Action {
                text: Shell.uiString("closeStack")
                enabled: !Shell.isRunning && Shell.stacks.length > 0
                onTriggered: Shell.closeStack()
            }
            Action {
                text: Shell.uiString("closeProject")
                enabled: !Shell.isRunning && Shell.stacks.length > 0
                onTriggered: Shell.closeProject()
            }
            MenuSeparator {}
            Action {
                text: Shell.uiString("saveProject")
                shortcut: StandardKey.Save
                enabled: !Shell.isRunning
                onTriggered: {
                    if (!Shell.saveProject(""))
                        saveProjectDialog.open()
                }
            }
            Action {
                text: Shell.uiString("saveProjectAs")
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
                text: Shell.depthMode ? Shell.uiString("exportDepthMap") : Shell.uiString("exportResult")
                shortcut: "Ctrl+E"
                enabled: !Shell.isRunning && Shell.hasDisplay
                onTriggered: Shell.exportInteractive()
            }
            Action {
                text: Shell.uiString("exportAllFused")
                enabled: !Shell.isRunning && Shell.fusedStackCount > 1
                onTriggered: exportAllDialog.open()
            }
            Action {
                text: Shell.uiString("exportAlignedFrames")
                shortcut: "Ctrl+Shift+E"
                enabled: !Shell.isRunning && Shell.canExportAligned
                onTriggered: exportAlignedDialog.open()
            }
            Action {
                text: Shell.uiString("exportRockingAnimation")
                enabled: !Shell.isRunning && Shell.canAnimate
                onTriggered: Shell.exportAnimationInteractive()
            }
        }
        Menu {
            title: Shell.uiString("editSectionTitle")
            Action {
                text: Shell.uiString("cropButton")
                shortcut: "C"
                enabled: Shell.canCrop && !Shell.cropMode
                onTriggered: Shell.beginCrop()
            }
            Action {
                text: qsTr("Swap Crop Orientation")
                shortcut: "X"
                enabled: Shell.cropMode
                onTriggered: Shell.toggleCropOrientation()
            }
            Action {
                text: qsTr("Accept Crop")
                enabled: Shell.cropMode
                onTriggered: Shell.acceptCrop()
            }
            Action {
                text: qsTr("Cancel Crop")
                enabled: Shell.cropMode
                onTriggered: Shell.cancelCrop()
            }
            MenuSeparator {}
            Action {
                text: qsTr("Settings…")
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
        Menu {
            title: qsTr("Help")
            Action {
                text: Shell.uiString("hyperfocalHelp")
                shortcut: "Ctrl+?"
                // The server 301s http → https; link the final URL.
                onTriggered: Qt.openUrlExternally(
                    "https://ethannicholas.com/hyperfocal/tutorial.html")
            }
            Action {
                text: Shell.uiString("aboutHyperfocal")
                onTriggered: aboutDialog.open()
            }
        }
    }

    FileDialog {
        id: openProjectDialog
        title: qsTr("Open a project")
        nameFilters: [qsTr("Hyperfocal projects (*.hyperfocal)")]
        onAccepted: Shell.openStack(selectedFile)
    }

    FileDialog {
        id: saveProjectDialog
        title: qsTr("Save project")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "hyperfocal"
        nameFilters: [qsTr("Hyperfocal projects (*.hyperfocal)")]
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

    // Keep the Stack panel's selected row in view — both for a manual
    // click and for fusion progress, which points selection at whichever
    // frame is currently being read/processed (see AppModel's fuse()
    // progress handler; the bridge's hf_selected_frame just mirrors
    // AppModel.selection, so this needs no bridge changes, only reacting
    // to it here like native's ScrollViewReader/scrollTo). framesChanged/
    // stacksChanged also fire for unrelated content edits (e.g. a
    // checkbox toggle) — track the last value scrolled to so those don't
    // yank the list back to the selected row out from under a user who
    // scrolled elsewhere on purpose.
    property int trackedSelectedFrame: -1
    property int trackedSelectedStack: -1
    function scrollSelectedFrameIntoView() {
        // Multi-selection (fusion progress selects the in-flight working
        // set): anchor on its LAST frame — the list is ascending, and a
        // minimal scroll leaves that row at the viewport's bottom edge with
        // the band's earlier rows visible above it (anchoring the first row
        // hides the rest of the band below the fold). Track the anchor, not
        // the whole set, so the view doesn't chase every membership change
        // within a stable working window.
        var sel = Shell.selectedFrames
        var frameIndex = sel.length > 0 ? sel[sel.length - 1] : Shell.selectedFrame
        if (frameIndex === trackedSelectedFrame
                && Shell.selectedStack === trackedSelectedStack) return
        trackedSelectedFrame = frameIndex
        trackedSelectedStack = Shell.selectedStack
        if (frameIndex < 0) return
        if (stackList.count > 1) {
            // Multi-stack tree: frame rows live inside each stack's
            // delegate (a Repeater, not their own ListView items), so
            // positionViewAtIndex only brings the stack's header on
            // screen — reach into its frame Repeater for the exact row.
            var stackIndex = Shell.selectedStack
            if (stackIndex < 0) return
            stackList.positionViewAtIndex(stackIndex, ListView.Contain)
            // The stack's delegate (and its nested frame Repeater) may not
            // be instantiated until layout settles after the scroll above —
            // finish the fine adjustment next tick, like native's dispatch
            // -after-layout comment on its own scrollTo call.
            Qt.callLater(function() {
                var stackItem = stackList.itemAtIndex(stackIndex)
                var rowItem = stackItem && stackItem.frameRepeater
                    ? stackItem.frameRepeater.itemAt(frameIndex) : null
                if (!rowItem) return
                var pos = rowItem.mapToItem(stackList.contentItem, 0, 0)
                if (pos.y < stackList.contentY)
                    stackList.contentY = pos.y
                else if (pos.y + rowItem.height > stackList.contentY + stackList.height)
                    stackList.contentY = pos.y + rowItem.height - stackList.height
            })
        } else {
            frameList.positionViewAtIndex(frameIndex, ListView.Contain)
        }
    }
    Connections {
        target: Shell
        function onFramesChanged() { scrollSelectedFrameIntoView() }
        function onStacksChanged() { scrollSelectedFrameIntoView() }
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
    // The native retouch keys: ↑/↓ cycle the source, space picks the
    // sharpest frame under the cursor, p/r toggle the PMax/eraser
    // layers, [ ] resize the brush; r starts retouching outside the
    // mode.
    Shortcut {
        sequence: "R"
        enabled: Shell.canRetouch && !Shell.retouchMode
        onActivated: Shell.enterRetouch()
    }
    Shortcut {
        sequence: "Up"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchCycleSource(-1)
    }
    Shortcut {
        sequence: "Down"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchCycleSource(1)
    }
    Shortcut {
        sequence: "Space"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchAutoPick()
    }
    Shortcut {
        sequence: "P"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchTogglePmax()
    }
    Shortcut {
        sequence: "D"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchToggleDmap()
    }
    Shortcut {
        sequence: "R"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchToggleResult()
    }
    Shortcut {
        sequence: "["
        enabled: Shell.retouchMode
        onActivated: Shell.retouchAdjustBrush(1 / 1.15)
    }
    Shortcut {
        sequence: "]"
        enabled: Shell.retouchMode
        onActivated: Shell.retouchAdjustBrush(1.15)
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
        // The native standard about panel, hand-built (Qt has no
        // equivalent of orderFrontStandardAboutPanel): icon, name,
        // version (build), the credits link + DNG SDK paragraph, and
        // the bundle copyright line.
        id: aboutDialog
        modal: true
        anchors.centerIn: parent
        padding: 24
        ColumnLayout {
            anchors.fill: parent
            spacing: 6
            Image {
                source: "qrc:/AppIcon.png"
                sourceSize: Qt.size(64, 64)
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: "Hyperfocal"
                font.bold: true
                font.pixelSize: 16
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: qsTr("Version %1 (%2)")
                      .arg(Shell.appVersion()).arg(Shell.appBuild())
                color: theme.textSecondary
                font.pixelSize: 11
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: "<a href=\"https://github.com/ethannicholas/hyperfocal\">"
                      + "https://github.com/ethannicholas/hyperfocal</a>"
                textFormat: Text.RichText
                font.pixelSize: 11
                Layout.alignment: Qt.AlignHCenter
                onLinkActivated: link => Qt.openUrlExternally(link)
            }
            Label {
                // One literal, not a concatenation: the catalog key is the
                // whole sentence, and a split expression would key on the
                // joined result while reading as five separate strings.
                text: qsTr("Includes the Adobe DNG SDK (DNG technology under license by Adobe Systems Incorporated) and the Qt framework under the GNU LGPL v3, plus other open-source libraries. See NOTICE.md for all third-party credits and licenses.")
                color: theme.textDim
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.preferredWidth: 300
                horizontalAlignment: Text.AlignHCenter
            }
            Label {
                text: "© 2026 Ethan Nicholas"   // i18n-exempt: a name
                color: theme.textDim
                font.pixelSize: 11
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    Dialog {
        id: settingsDialog
        title: qsTr("Settings")
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
                text: Shell.uiString("settingsOrderByCaptureTime")
                onToggled: Shell.setBoolSetting("order-by-capture", checked)
            }
            CheckBox {
                id: alignToggle
                text: Shell.uiString("settingsAlignFrames")
                onToggled: Shell.setBoolSetting("align", checked)
            }
            CheckBox {
                id: normalizeToggle
                text: Shell.uiString("settingsEvenOutExposure")
                onToggled: Shell.setBoolSetting("normalize-exposure", checked)
            }
            CheckBox {
                id: gpuToggle
                text: Shell.uiString("settingsUseGPU")
                enabled: Shell.gpuAvailable()
                onToggled: Shell.setBoolSetting("gpu", checked)
            }
            CheckBox {
                id: diskToggle
                text: Shell.uiString("settingsCacheFrames")
                onToggled: Shell.setBoolSetting("disk-cache", checked)
            }
        }
    }

    FolderDialog {
        id: openDialog
        title: qsTr("Choose a stack folder")
        onAccepted: Shell.openStack(selectedFolder)
    }

    FolderDialog {
        id: newProjectDialog
        title: qsTr("Choose a stack: a folder of frames")
        onAccepted: Shell.newProject(selectedFolder)
    }

    FolderDialog {
        id: exportAllDialog
        title: qsTr("Export every fused stack to a folder")
        onAccepted: Shell.exportAll(selectedFolder)
    }

    FolderDialog {
        id: exportAlignedDialog
        title: qsTr("Export aligned frames to a folder")
        onAccepted: Shell.exportAligned(selectedFolder)
    }



    // A pane with the tone LUT shader over its layer — the native
    // ToneFilteredPaneView's color-cube-on-layer, mirrored. The PaneItem
    // stays on top (hideSource hides its direct rendering) so it keeps
    // receiving wheel/drag events.
    // Style-independent activity spinner: the platform styles' native
    // BusyIndicator is an asset (macOS: animated webp) that renders
    // blank when Qt lacks the image plugin — a drawn arc can't fail.
    component Spinner: Canvas {
        id: spin
        property color color: theme.textSecondary
        property int thickness: 3
        width: 28
        height: 28
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = String(spin.color)
            ctx.lineWidth = spin.thickness
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.arc(width / 2, height / 2,
                    (Math.min(width, height) - spin.thickness) / 2,
                    0, Math.PI * 1.5)
            ctx.stroke()
        }
        onColorChanged: requestPaint()
        RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 900
            loops: Animation.Infinite
            running: spin.visible
        }
    }

    component TonedPane: ColumnLayout {
        id: toned
        property bool inputSource: false
        property bool dataDisplay: false
        property string title: ""
        property string hint: ""
        // Decode-in-flight feedback, the native PreviewPane's two loading
        // states: an empty pane centers a spinner (in place of the hint);
        // a pane that already shows an image gets a floating badge while
        // the replacement decodes (big frames take seconds and the pane
        // serves the previous image until the new one lands).
        property bool loading: false
        property bool hasImage: false
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
            color: theme.headerBar
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 4
                spacing: 6
                Label {
                    Layout.fillWidth: true
                    text: toned.title
                    color: theme.textSecondary
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
            Rectangle { anchors.fill: parent; color: theme.well; z: -1 }
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
                    && !(toned.loading && !toned.hasImage)
                color: theme.textFaint
                font.pixelSize: 13
            }
            Spinner {
                anchors.centerIn: parent
                visible: toned.loading && !toned.hasImage
            }
            Rectangle {
                anchors.centerIn: parent
                visible: toned.loading && toned.hasImage
                width: badge.width + 20
                height: badge.height + 16
                radius: 8
                color: theme.overlayCardSoft
                Spinner {
                    id: badge
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    color: theme.textSecondary
                }
            }
        }
    }

    // Every hover-triggered tooltip in the shell (native's help-tag
    // equivalent) goes through this: a real hover delay (native tooltips
    // don't pop instantly), an opaque background readable over busy image
    // content, and word-wrapping at a fixed width instead of a single
    // stretched-out line.
    // Popup (ToolTip's base) does NOT pick up its visual parent from QML
    // nesting the way an Item does — every instance below sets `parent:`
    // explicitly to the widget it's hovering, or it renders in some
    // unrelated default spot instead of near that widget.
    component InfoTip: ToolTip {
        id: tip
        delay: 600
        x: 0
        y: parent ? parent.height + 4 : 0
        contentItem: Label {
            text: tip.text
            wrapMode: Text.WordWrap
            color: theme.textPrimary
            font.pixelSize: 12
        }
        background: Rectangle {
            color: theme.tooltipFill
            border.color: theme.tooltipBorder
            border.width: 1
            radius: 6
        }
        width: 260
    }

    // A small (i) affordance next to a label, mirroring the algorithm
    // picker's info icon — the tooltip triggers on the icon itself, not
    // the whole row, so hovering the label or control doesn't surprise
    // the user with a popup.
    component InfoIcon: Label {
        id: icon
        property string tip: ""
        text: "ⓘ"   // ⓘ
        color: theme.textSecondary
        font.pixelSize: 12
        HoverHandler { id: iconHover }
        InfoTip { parent: icon; visible: iconHover.hovered; text: icon.tip }
    }

    component SidebarSlider: ColumnLayout {
        id: sliderRoot
        required property string sliderId
        required property string label
        required property real from
        required property real to
        property string format: "%1"
        property int decimals: 2
        // Display-only multiplier: the percent sliders keep their 0…1 model
        // value and read as 0…100 (native LabeledSlider.displayScale). Never
        // touches what goes back through the bridge.
        property real displayScale: 1
        // Native formats the tone sliders "%+.0f" — the sign is always
        // shown, so a centred slider reads "+0", not "0".
        property bool showsSign: false
        // Matches native's LabeledSlider.help: an info icon next to the
        // label carries the tooltip (below, InfoIcon), same as the
        // algorithm picker.
        property string tip: ""
        // A hair below zero formats as "-0.00" (drag back toward zero and
        // stop a fraction short) — show the zero it rounds to instead, the
        // same guard native's displayString applies.
        readonly property string displayValue: {
            var s = (control.value * displayScale).toFixed(decimals)
            if (Number(s) === 0) s = (0).toFixed(decimals)
            return showsSign && Number(s) >= 0 ? "+" + s : s
        }
        spacing: 2
        Layout.fillWidth: true
        RowLayout {
            id: valueRow
            Layout.fillWidth: true
            spacing: 4
            // The label and its (i) icon are one unit — the icon sits
            // right after the label text (a suffix), never drifting to
            // the right edge as a prefix to the value. fillWidth capped
            // at implicitWidth lets the label shrink (and elide) when
            // the sidebar is tight without ever growing past its text;
            // the spacer after the icon takes the slack, and the value
            // keeps its natural width (wider style fonts on Windows
            // overflowed the row when the value was squeezed instead).
            Label {
                text: label
                color: theme.textSecondary
                font.pixelSize: 12
                Layout.fillWidth: true
                // Both pins are needed: maximum stops the label from
                // growing past its text (which parked the icon at the
                // right edge), and preferred stops the layout from
                // handing it LESS than its text when space is plentiful
                // (fillWidth surplus distribution otherwise elided
                // "Median radius" in a half-empty row).
                // Ceil, not the raw implicitWidth: the layout hands some
                // items a whole-pixel width, and elide fires on the
                // sub-pixel shortfall — "Median radius" at 79px vs an
                // implicit 79.28 elided a full character for 0.28px.
                Layout.preferredWidth: Math.ceil(implicitWidth)
                Layout.maximumWidth: Math.ceil(implicitWidth)
                elide: Text.ElideRight
            }
            InfoIcon { tip: sliderRoot.tip; visible: tip.length > 0 }
            Item { Layout.fillWidth: true }
            Label {
                id: valueLabel
                text: format.arg(displayValue)
                color: theme.textDim
                font.pixelSize: 12
                // Monospace keeps the value from jittering during drags;
                // Menlo is macOS-only (its Windows fallback rendered wide).
                font.family: Qt.platform.os === "osx" ? "Menlo"
                           : Qt.platform.os === "windows" ? "Consolas"
                           : "monospace"
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

    // Grouped-form card — the native sidebar renders each Form section
    // on a rounded, slightly-lighter background (formStyle(.grouped));
    // the section header is the card's first row, like native.
    component SidebarCard: Rectangle {
        default property alias content: cardColumn.data
        Layout.fillWidth: true
        implicitHeight: cardColumn.implicitHeight + 20
        color: theme.cardFill
        border.color: theme.cardBorder
        border.width: 1
        radius: 8
        ColumnLayout {
            id: cardColumn
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10
        }
    }

    // The rule under a card's title row — the native form draws the same
    // separator between its header row and the section content.
    component CardRule: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: theme.cardBorder
    }

    // Native sectionHeader: chevron + title as one toggle for the
    // model-persisted collapse state; trailing children (Reset, All/
    // None…) stay outside the toggle's effect but inside the row.
    component SectionHeader: RowLayout {
        id: header
        required property string title
        required property string section
        property string subtitle: ""
        default property alias trailing: trailingRow.data
        readonly property bool collapsed:
            Shell.collapsedSections.indexOf(section) >= 0
        // Leading indent that puts a content row's label flush with the
        // TITLE text (not the chevron): the chevron's square cell plus
        // this row's spacing. Derived, not hardcoded — it tracks the
        // glyph's rendered size.
        readonly property real textIndent: chevronCell.implicitWidth + spacing
        Layout.fillWidth: true
        spacing: 6
        // Headers are always as tall as their trailing flat buttons
        // (Reset, All/None) would make them, so a button appearing or
        // disappearing never shifts the layout. The ghost is invisible:
        // layouts skip it (no cell, no spacing), but its implicitHeight
        // still reports the style's real button height.
        Layout.minimumHeight: heightGhost.implicitHeight
        Button {
            id: heightGhost
            visible: false
            flat: true
            text: "X"
            font.pixelSize: 11
        }
        Item {
            id: chevronCell
            // Native's chevron.right/chevron.down: a real chevron,
            // rotating to point down when expanded (the triangle
            // glyphs render too small to read as disclosure arrows).
            // Square cell sized to the glyph's rotated extent — the
            // narrow unrotated layout cell otherwise lets the rotated
            // glyph overhang into the sidebar clip and lose an edge.
            implicitWidth: chevronGlyph.paintedHeight
            implicitHeight: chevronGlyph.paintedHeight
            Text {
                id: chevronGlyph
                anchors.centerIn: parent
                text: "\u276f"
                color: theme.textDim
                font.pixelSize: 12
                font.bold: true
                rotation: header.collapsed ? 0 : 90
            }
        }
        Label { text: header.title; color: theme.textPrimary; font.bold: true }
        // The subtitle doubles as the row's flexing element (it elides
        // under pressure). This keeps the header compressible: a
        // ColumnLayout whose set width is below any child's minimum lays
        // EVERYTHING out at that minimum — one incompressible header made
        // the whole sidebar overflow its 260px column by 19px under
        // Fusion's wider buttons, clipping every card at the edge.
        Label {
            text: header.subtitle
            color: theme.textDim
            font.pixelSize: 11
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
        RowLayout { id: trailingRow; spacing: 6 }
        TapHandler { onTapped: Shell.toggleSection(header.section) }
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
            // Explicit arithmetic, not availableWidth: Fusion's ScrollView
            // reports availableWidth without the right padding, which ran
            // the cards to the clipped 280px edge (slider values cut off).
            width: sidebarScroll.width - sidebarScroll.leftPadding
                   - sidebarScroll.rightPadding
            // Stretch to the viewport when content fits, so the Export
            // button stays pinned to the bottom.
            height: Math.max(implicitHeight, sidebarScroll.availableHeight)
            spacing: 10

            // Stack card: header inside the card like every other section
            // (and like native); the title reads "Stacks" once a second
            // stack exists, when the flat frame list yields to the tree.
            SidebarCard {
            SectionHeader {
                id: stackHeader
                title: stackList.count > 1 ? Shell.uiString("stackPlural") : Shell.uiString("stackSingular")
                section: "stack"
                // "N of M" included count, the native stack.count.
                subtitle: {
                    if (Shell.frames.length === 0) return ""
                    var n = 0
                    for (var i = 0; i < Shell.frames.length; ++i)
                        if (Shell.frames[i].included) ++n
                    return qsTr("%1 of %2").arg(n).arg(Shell.frames.length)
                }
                Button {
                    text: Shell.uiString("includeAllFrames")
                    visible: frameList.count > 0
                    enabled: !Shell.isRunning
                    flat: true
                    font.pixelSize: 11
                    // Tight header buttons: Fusion's Button background
                    // imposes a large minimum implicit width (~80px) that
                    // crowded the header row until the whole sidebar
                    // column overflowed; size these to their text.
                    leftPadding: 8
                    rightPadding: 8
                    Layout.preferredWidth: implicitContentWidth
                                           + leftPadding + rightPadding
                    onClicked: Shell.setAllFramesIncluded(true)
                }
                Button {
                    text: Shell.uiString("includeNoFrames")
                    visible: frameList.count > 0
                    enabled: !Shell.isRunning
                    flat: true
                    font.pixelSize: 11
                    // Tight header buttons: Fusion's Button background
                    // imposes a large minimum implicit width (~80px) that
                    // crowded the header row until the whole sidebar
                    // column overflowed; size these to their text.
                    leftPadding: 8
                    rightPadding: 8
                    Layout.preferredWidth: implicitContentWidth
                                           + leftPadding + rightPadding
                    onClicked: Shell.setAllFramesIncluded(false)
                }
            }
            ColumnLayout {
            visible: !stackHeader.collapsed
            Layout.fillWidth: true
            spacing: 10
            CardRule {}
            // Stack tree (flat mirror): shown once a second stack exists,
            // like the native sidebar. Row click selects (stash/install);
            // the checkbox is the batch-fuse opt-in.
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
                    // Exposes the nested frame Repeater below so
                    // scrollSelectedFrameIntoView() can reach a specific
                    // frame row from outside this delegate instance.
                    property alias frameRepeater: frameRepeater
                    RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    // Hand-rolled disclosure chevron (the native tree
                    // avoids DisclosureGroup for accessibility too).
                    Item {
                        implicitWidth: 22
                        implicitHeight: 22
                        Text {
                            anchors.centerIn: parent
                            text: "\u276f"
                            color: theme.textDim
                            font.pixelSize: 10
                            font.bold: true
                            rotation: stackDelegate.modelData.expanded
                                      ? 90 : 0
                        }
                        TapHandler {
                            onTapped: Shell.setStackExpanded(
                                stackDelegate.index,
                                !stackDelegate.modelData.expanded)
                        }
                    }
                    CheckBox {
                        id: enabledCheckBox
                        checked: modelData.enabled
                        enabled: !Shell.isRunning
                        onToggled: Shell.setStackEnabled(index, checked)
                        HoverHandler { id: enabledHover }
                        InfoTip { parent: enabledCheckBox; visible: enabledHover.hovered; text: Shell.uiString("includeStackTip") }
                    }
                    Image {
                        // Middle-frame thumbnail, like native's stack rows.
                        // thumbToken is 0 until the background generation
                        // lands (the item collapses away meanwhile) and
                        // cache-busts the URL when the source frame changes.
                        visible: modelData.thumbToken !== 0
                        source: modelData.thumbToken !== 0
                                ? "image://hfthumb/" + index + "?" + modelData.thumbToken
                                : ""
                        sourceSize.width: 60
                        sourceSize.height: 42
                        Layout.preferredWidth: 60
                        Layout.preferredHeight: 42
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Label {
                        text: modelData.name
                        // Native: the title alone dims when the stack
                        // is excluded from batch fuse; glyphs, count,
                        // and chevron keep their normal colors.
                        color: !modelData.enabled ? theme.textFaint
                             : index === Shell.selectedStack
                               ? theme.textPrimary : theme.textSecondary
                        font.bold: index === Shell.selectedStack
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        TapHandler {
                            enabled: !Shell.isRunning
                            onTapped: Shell.selectStack(index)
                        }
                    }
                    Label {
                        id: orderBadge
                        // Load-time frame-order warning badge.
                        text: "△"
                        visible: modelData.orderWarning !== ""
                        color: theme.warn
                        HoverHandler { id: orderHover }
                        InfoTip { parent: orderBadge; visible: orderHover.hovered; text: modelData.orderWarning }
                    }
                    Label {
                        id: statusBadge
                        // The native tree's status glyph, textified:
                        // fusing / fused / failed (hover = message).
                        text: modelData.status === 1 ? "…"
                            : modelData.status === 2 ? "✓"
                            : modelData.status === 3 ? "⚠" : ""
                        color: modelData.status === 3 ? theme.warn : theme.ok
                        HoverHandler { id: hover }
                        InfoTip {
                            parent: statusBadge
                            visible: (modelData.status === 3 || modelData.status === 2)
                                     && hover.hovered
                            text: modelData.status === 3 ? modelData.failure
                                                          : Shell.uiString("fusedStatusTip")
                        }
                    }
                    Label {
                        text: stackDelegate.modelData.frameCount
                        color: theme.textDim
                        font.pixelSize: 11
                    }
                    }
                    // Nested frame rows while disclosed; dimmed and
                    // inert when the stack is disabled, like native.
                    Repeater {
                        id: frameRepeater
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
                                // Click selects the frame, like the flat
                                // list — the input pane follows (another
                                // stack's frame switches stacks with it).
                                text: modelData.name
                                color: modelData.included ? theme.textPrimary
                                                          : theme.textFaint
                                font.bold: stackDelegate.index === Shell.selectedStack
                                           && Shell.selectedFrames.indexOf(index) !== -1
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                                TapHandler {
                                    onTapped: Shell.selectStackFrame(
                                        stackDelegate.index, index)
                                }
                            }
                            Label {
                                id: nestedIssueBadge
                                text: "⚠"
                                visible: modelData.issue !== ""
                                color: theme.warn
                                HoverHandler { id: nestedIssueHover }
                                InfoTip { parent: nestedIssueBadge; visible: nestedIssueHover.hovered; text: modelData.issue }
                            }
                        }
                    }
                }
            }

            // Native empty state: hint + Open Folder…, inside the card,
            // only while no stack is open.
            Label {
                Layout.fillWidth: true
                visible: stackList.count === 0 && frameList.count === 0
                text: Shell.uiString("dropFolderHint")
                color: theme.textDim
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
            Button {
                Layout.fillWidth: true
                visible: stackList.count === 0 && frameList.count === 0
                text: Shell.uiString("openFolder")
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
                        color: modelData.included ? theme.textPrimary : theme.textFaint
                        font.bold: Shell.selectedFrames.indexOf(index) !== -1
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        TapHandler { onTapped: Shell.selectFrame(index) }
                    }
                    Label {
                        id: issueBadge
                        // Fuse-time issue badge (misfire/misalignment).
                        text: "⚠"
                        visible: modelData.issue !== ""
                        color: theme.warn
                        HoverHandler { id: issueHover }
                        InfoTip { parent: issueBadge; visible: issueHover.hovered; text: modelData.issue }
                    }
                }
            }
            }
            }

            SidebarCard {
            SectionHeader {
                id: fusionHeader
                title: Shell.uiString("fusionSectionTitle")
                section: "fusion"
                Button {
                    text: Shell.uiString("reset")
                    visible: !Shell.fusionDefault
                    enabled: !Shell.isRunning
                    flat: true
                    font.pixelSize: 11
                    // Tight header buttons: Fusion's Button background
                    // imposes a large minimum implicit width (~80px) that
                    // crowded the header row until the whole sidebar
                    // column overflowed; size these to their text.
                    leftPadding: 8
                    rightPadding: 8
                    Layout.preferredWidth: implicitContentWidth
                                           + leftPadding + rightPadding
                    onClicked: Shell.resetFusion()
                }
            }
            ColumnLayout {
                visible: !fusionHeader.collapsed
                Layout.fillWidth: true
                spacing: 10
                CardRule {}
                // Labeled controls sit one text-indent in, so their labels
                // line up with the header's title text (the buttons below
                // keep the card's full width, like native).
                ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: fusionHeader.textIndent
                spacing: 10
                // Algorithm selector: DMap (depth map) or PMax (pyramid
                // fusion), each with an info tooltip. Only DMap carries depth;
                // the persisted raw value is "dmap"/"pmax". Native lays this
                // out as a LabeledContent — "Algorithm:" in the Form's label
                // column, the stacked radios in the content column beside it —
                // so this is a row, not a label above the radios. The radios
                // keep their own tight spacing rather than inheriting the
                // card's inter-control gap, which spread them apart.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    // LabeledContent aligns its label with the FIRST row of
                    // the content column, not the column's middle. The
                    // invisible ghost gives the label cell exactly one radio
                    // row's height, so centering in it lands on "DMap"
                    // (layouts skip invisible items but still read their
                    // implicitHeight — the SectionHeader trick).
                    Item {
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: algorithmLabel.implicitWidth
                        implicitHeight: radioGhost.implicitHeight
                        RadioButton { id: radioGhost; visible: false; text: "X" }
                        Label {
                            id: algorithmLabel
                            anchors.verticalCenter: parent.verticalCenter
                            text: Shell.uiString("algorithmLabel")
                            color: theme.textSecondary
                            font.pixelSize: 12
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3
                        Repeater {
                            model: [
                                // "DMap"/"PMax" are proper algorithm names,
                                // never translated — the same call AppCore's
                                // DisplayNamed makes for FusionMethod (see
                                // Localization.swift).
                                { key: "dmap", label: "DMap",
                                  tip: Shell.uiString("algorithmDMapTip") },
                                { key: "pmax", label: "PMax",
                                  tip: Shell.uiString("algorithmPMaxTip") }
                            ]
                            delegate: RowLayout {
                                Layout.fillWidth: true
                                RadioButton {
                                    text: modelData.label
                                    checked: Shell.fusionAlgorithm === modelData.key
                                    enabled: !Shell.isRunning
                                    onClicked: Shell.fusionAlgorithm = modelData.key
                                }
                                InfoIcon { tip: modelData.tip }
                                Item { Layout.fillWidth: true }
                            }
                        }
                    }
                }
                // DMap sliders (shown for the depth-map algorithm)
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.sharpness"
                    label: Shell.uiString("sliderSharpnessLabel"); from: 1; to: 16; format: qsTr("%1 px")
                    tip: Shell.uiString("sliderSharpnessTip")
                    decimals: 1
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.noise-floor"
                    label: Shell.uiString("sliderNoiseFloorLabel"); from: 0.01; to: 1
                    tip: Shell.uiString("sliderNoiseFloorTip")
                    // A fraction in the model, a percentage on screen.
                    format: "%1%"
                    displayScale: 100; decimals: 0
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.median-radius"
                    label: Shell.uiString("sliderMedianRadiusLabel"); from: 0; to: 32; format: qsTr("%1 px")
                    tip: Shell.uiString("sliderMedianRadiusTip")
                    decimals: 0
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.blend-radius"
                    label: Shell.uiString("sliderBlendRadiusLabel"); from: 0.75; to: 4
                    tip: Shell.uiString("sliderBlendRadiusTip")
                    enabled: !Shell.isRunning
                }
                // PMax debloom sliders (shown for the pyramid-fusion algorithm)
                SidebarSlider {
                    visible: Shell.fusionAlgorithm === "pmax"
                    sliderId: "fusion.slider.debloom-levels"
                    label: Shell.uiString("sliderDebloomLevelsLabel"); from: 0; to: 8; format: "%1"
                    tip: Shell.uiString("sliderDebloomLevelsTip")
                    decimals: 0
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm === "pmax"
                    sliderId: "fusion.slider.focus-threshold"
                    label: Shell.uiString("sliderFocusThresholdLabel"); from: 0; to: 0.3
                    tip: Shell.uiString("sliderFocusThresholdTip")
                    enabled: !Shell.isRunning
                }
                }
                Button {
                    Layout.fillWidth: true
                    text: Shell.uiString("fuseStack")
                    enabled: Shell.canFuse
                    highlighted: true
                    onClicked: Shell.fuse()
                }
                Button {
                    id: fuseEnabledButton
                    Layout.fillWidth: true
                    visible: stackList.count > 1
                    text: qsTr("Fuse %1 Stacks").arg(Shell.pendingStackCount)
                    enabled: Shell.pendingStackCount > 0 && !Shell.isRunning
                    onClicked: Shell.fuseEnabledStacks()
                    HoverHandler { id: fuseEnabledHover }
                    InfoTip { parent: fuseEnabledButton; visible: fuseEnabledHover.hovered; text: Shell.uiString("fuseEnabledStacksTip") }
                }
            }
            }

            SidebarCard {
            SectionHeader {
                id: toneHeader
                title: Shell.uiString("toneSectionTitle")
                section: "tone"
                Button {
                    text: Shell.uiString("reset")
                    visible: !Shell.toneNeutral
                    flat: true
                    font.pixelSize: 11
                    // Tight header buttons: Fusion's Button background
                    // imposes a large minimum implicit width (~80px) that
                    // crowded the header row until the whole sidebar
                    // column overflowed; size these to their text.
                    leftPadding: 8
                    rightPadding: 8
                    Layout.preferredWidth: implicitContentWidth
                                           + leftPadding + rightPadding
                    onClicked: Shell.resetTone()
                }
            }
            ColumnLayout {
                visible: !toneHeader.collapsed
                Layout.fillWidth: true
                spacing: 10
                CardRule {}
                // Every tone control reads signed (native "%+.2f EV" /
                // "%+.0f"): these are offsets from neutral, so the sign is
                // part of the value, not noise. One text-indent in, so the
                // labels line up with the header's title text.
                ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: toneHeader.textIndent
                spacing: 10
                SidebarSlider {
                    sliderId: "tone.slider.exposure"
                    label: Shell.uiString("sliderExposureLabel"); from: -5; to: 5; format: qsTr("%1 EV")
                    tip: Shell.uiString("sliderExposureTip")
                    showsSign: true
                }
                SidebarSlider {
                    sliderId: "tone.slider.contrast"
                    label: Shell.uiString("sliderContrastLabel"); from: -100; to: 100; decimals: 0
                    tip: Shell.uiString("sliderContrastTip")
                    showsSign: true
                }
                SidebarSlider {
                    sliderId: "tone.slider.highlights"
                    label: Shell.uiString("sliderHighlightsLabel"); from: -100; to: 100; decimals: 0
                    tip: Shell.uiString("sliderHighlightsTip")
                    showsSign: true
                }
                SidebarSlider {
                    sliderId: "tone.slider.shadows"
                    label: Shell.uiString("sliderShadowsLabel"); from: -100; to: 100; decimals: 0
                    tip: Shell.uiString("sliderShadowsTip")
                    showsSign: true
                }
                SidebarSlider {
                    sliderId: "tone.slider.whites"
                    label: Shell.uiString("sliderWhitesLabel"); from: -100; to: 100; decimals: 0
                    tip: Shell.uiString("sliderWhitesTip")
                    showsSign: true
                }
                SidebarSlider {
                    sliderId: "tone.slider.blacks"
                    label: Shell.uiString("sliderBlacksLabel"); from: -100; to: 100; decimals: 0
                    tip: Shell.uiString("sliderBlacksTip")
                    showsSign: true
                }
                }
            }
            }

            SidebarCard {
            SectionHeader {
                id: editHeader
                title: Shell.uiString("editSectionTitle")
                section: "retouch"
            }
            ColumnLayout {
                visible: !editHeader.collapsed
                Layout.fillWidth: true
                spacing: 10
                CardRule {}
                Button {
                    id: cropButton
                    Layout.fillWidth: true
                    visible: !Shell.retouchMode && !Shell.cropMode
                    text: Shell.uiString("cropButton")
                    enabled: Shell.canCrop
                    onClicked: Shell.beginCrop()
                    HoverHandler { id: cropButtonHover }
                    InfoTip { parent: cropButton; visible: cropButtonHover.hovered; text: Shell.uiString("cropTip") }
                }
                Button {
                    Layout.fillWidth: true
                    visible: !Shell.retouchMode && !Shell.cropMode
                    text: Shell.retouchHasEdits ? Shell.uiString("continueRetouching")
                                                : Shell.uiString("startRetouching")
                    enabled: Shell.canRetouch
                    onClicked: Shell.enterRetouch()
                }

                // Crop-mode controls replace the Edit buttons, under a
                // "Crop" sub-header — the native CropControls placement.
                Label {
                    visible: Shell.cropMode
                    text: Shell.uiString("cropHeader"); color: theme.textPrimary; font.bold: true
                }
                RowLayout {
                    visible: Shell.cropMode
                    Layout.fillWidth: true
                    Label { text: Shell.uiString("aspectRatioLabel"); color: theme.textSecondary }
                    ComboBox {
                        Layout.fillWidth: true
                        // The aspect value persists through the bridge:
                        // the model keeps it verbatim and only `display` is
                        // translated, so a localized run never writes a
                        // translated rawValue back (the DisplayNamed rule).
                        model: [
                            { value: "Original", display: qsTr("Original") },
                            { value: "Custom", display: qsTr("Custom") },
                            { value: "1:1", display: "1:1" },
                            { value: "3:2", display: "3:2" },
                            { value: "5:4", display: "5:4" },
                            { value: "4:3", display: "4:3" },
                            { value: "16:9", display: "16:9" }
                        ]
                        textRole: "display"
                        valueRole: "value"
                        currentIndex: {
                            for (var i = 0; i < model.length; ++i)
                                if (model[i].value === Shell.cropAspect)
                                    return i
                            return 0
                        }
                        onActivated: index => Shell.cropAspect = model[index].value
                    }
                    Button {
                        id: orientationButton
                        // Icon button in the aspect row, like native's
                        // symbol button: the current orientation's
                        // rectangle with a rotation arrow (drawn SVGs — SF
                        // Symbols can't ship in a cross-platform shell;
                        // the style tints them via icon.color).
                        icon.source: Shell.cropPortrait
                                     ? "crop-portrait.svg"
                                     : "crop-landscape.svg"
                        icon.width: 18
                        icon.height: 18
                        onClicked: Shell.toggleCropOrientation()
                        InfoTip { parent: orientationButton; visible: orientationButton.hovered; text: Shell.uiString("swapCropOrientationTip") }
                    }
                }
                RowLayout {
                    visible: Shell.cropMode
                    Layout.fillWidth: true
                    Button {
                        Layout.fillWidth: true
                        highlighted: true
                        text: Shell.uiString("accept")
                        onClicked: Shell.acceptCrop()
                    }
                    Button {
                        Layout.fillWidth: true
                        text: Shell.uiString("cancel")
                        onClicked: Shell.cancelCrop()
                    }
                }

                Label {
                    visible: Shell.retouchMode
                    text: Shell.uiString("retouchingTitle"); color: theme.textPrimary; font.bold: true
                }
                SidebarSlider {
                    visible: Shell.retouchMode
                    sliderId: "retouch.slider.brush-size"
                    label: Shell.uiString("sliderBrushSizeLabel"); from: 1; to: 800; decimals: 0
                    format: qsTr("%1 px")
                    tip: Shell.uiString("sliderBrushSizeTip")
                }
                SidebarSlider {
                    visible: Shell.retouchMode
                    sliderId: "retouch.slider.softness"
                    label: Shell.uiString("sliderSoftnessLabel"); from: 0; to: 1
                    tip: Shell.uiString("sliderSoftnessTip")
                    // Feathered fraction: 0…1 in the model, 0%…100% shown.
                    format: "%1%"
                    displayScale: 100; decimals: 0
                }
                ColumnLayout {
                    visible: Shell.retouchMode
                    Layout.fillWidth: true
                    spacing: 2
                    RowLayout {
                        spacing: 4
                        Label {
                            text: Shell.uiString("retouchFromLabel")
                            color: theme.textSecondary
                            font.pixelSize: 12
                        }
                        InfoIcon { tip: Shell.uiString("retouchSourceTip") }
                    }
                    RadioButton {
                        text: Shell.uiString("retouchSourceImage")
                        checked: Shell.retouchSourceKind === 0
                        onClicked: Shell.retouchSourceKind = 0
                    }
                    RadioButton {
                        text: Shell.uiString("retouchPMaxResult")
                        checked: Shell.retouchSourceKind === 1
                        onClicked: Shell.retouchSourceKind = 1
                    }
                    RadioButton {
                        text: Shell.uiString("retouchDMapResult")
                        checked: Shell.retouchSourceKind === 2
                        onClicked: Shell.retouchSourceKind = 2
                    }
                }
                Button {
                    Layout.fillWidth: true
                    visible: Shell.retouchMode
                    enabled: Shell.retouchHasEdits
                    text: Shell.uiString("revertAll")
                    onClicked: Shell.revertRetouch()
                }
                Button {
                    Layout.fillWidth: true
                    visible: Shell.retouchMode
                    highlighted: true
                    text: Shell.uiString("doneRetouching")
                    onClicked: Shell.exitRetouch()
                }

                Label {
                    Layout.fillWidth: true
                    visible: Shell.displayCrop.width > 0
                    text: Shell.displayCropAngle !== 0
                        ? qsTr("Cropped to %1×%2, %3°")
                          .arg(Shell.displayCrop.width)
                          .arg(Shell.displayCrop.height)
                          .arg(Shell.displayCropAngle.toFixed(1))
                        : qsTr("Cropped to %1×%2")
                          .arg(Shell.displayCrop.width)
                          .arg(Shell.displayCrop.height)
                    color: theme.textDim
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            }

            Item { Layout.fillHeight: true }

            SidebarCard {
            SectionHeader {
                id: exportHeader
                title: Shell.uiString("exportSectionTitle")
                section: "export"
            }
            ColumnLayout {
                visible: !exportHeader.collapsed
                Layout.fillWidth: true
                spacing: 10
                CardRule {}
                Button {
                    Layout.fillWidth: true
                    text: Shell.depthMode ? Shell.uiString("exportDepthMap") : Shell.uiString("exportResult")
                    enabled: !Shell.isRunning && Shell.hasDisplay
                    onClicked: Shell.exportInteractive()
                }
            }
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
                    title: Shell.retouchMode
                        ? qsTr("Source: %1   ↑/↓ cycle · space picks sharpest")
                          .arg(Shell.retouchSourceName)
                        : Shell.inputTitle !== "" ? Shell.inputTitle
                                                  : Shell.uiString("inputTitle")
                    // A decode that failed outranks both hints: without this the
                    // pane claims nothing is selected while a frame plainly is.
                    // Matches the native pane, which reads the same model value.
                    hint: Shell.hasInput ? ""
                        : Shell.inputError !== "" ? Shell.inputError
                        : Shell.frames.length === 0
                            ? qsTr("Open a stack to begin")
                            : Shell.uiString("selectFrameHint")
                    // Mid-fuse the pane cycles processing sources — the
                    // spinner would just flicker (native gates the same
                    // way); the retouch source keeps its own status label.
                    loading: !Shell.retouchMode && Shell.inputLoading
                        && !Shell.isRunning
                    hasImage: Shell.hasInput
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // While retouching, this pane shows the SOURCE layer
                    // (frame slice / PMax / eraser preview).
                    Binding {
                        target: inputPane.item
                        property: "retouchSource"
                        value: Shell.retouchMode
                    }
                    // The source pane mirrors the brush circle, like
                    // native — you aim on either side.
                    BrushCircle {
                        parent: inputPane.contentArea
                        anchors.fill: parent
                        pane: inputPane.item
                        active: Shell.retouchMode
                    }
                    Label {
                        parent: inputPane.contentArea
                        anchors.centerIn: parent
                        visible: Shell.retouchMode
                            && (Shell.retouchSourceLoading
                                || Shell.retouchSourceError !== "")
                        text: Shell.retouchSourceError !== ""
                            ? Shell.retouchSourceError
                            : Shell.retouchSourceStatus !== ""
                                ? Shell.retouchSourceStatus
                                : Shell.uiString("loadingSource")
                        color: theme.textSecondary
                        font.pixelSize: 13
                        padding: 8
                        background: Rectangle {
                            color: theme.overlayCardSoft
                            radius: 6
                        }
                    }
                }
                TonedPane {
                    id: outputPane
                    Layout.preferredWidth: 1
                    title: Shell.retouchMode
                        ? (Shell.depthMode
                           ? qsTr("Retouched Depth")
                           : Shell.uiString("retouchedOutputHint"))
                        : Shell.uiString("outputTitle")
                    dataDisplay: Shell.displayIsData
                    hint: Shell.hasDisplay ? ""
                        : Shell.canFuse ? Shell.uiString("pressFuseStackHint")
                                        : Shell.uiString("noOutputYet")
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Segmented mode picker in the pane header, the
                    // native output.mode placement.
                    Row {
                        parent: outputPane.headerArea
                        spacing: 1
                        Button {
                            text: qsTr("Result")
                            checkable: true
                            autoExclusive: true
                            checked: !Shell.depthMode
                            onClicked: Shell.depthMode = false
                            // No width override: a hardcoded 64 elided
                            // German "Ergebnis" and Russian "Результат", and
                            // deriving it from implicitContentWidth doesn't
                            // help either — headerSlot sizes from
                            // childrenRect, which doesn't re-evaluate when a
                            // child's implicit width is itself a binding.
                            // The natural button width is stable and fits.
                            leftPadding: 10
                            rightPadding: 10
                            implicitHeight: 22
                            font.pixelSize: 11
                        }
                        Button {
                            text: qsTr("Depth")
                            checkable: true
                            autoExclusive: true
                            checked: Shell.depthMode
                            onClicked: Shell.depthMode = true
                            // No width override: a hardcoded 64 elided
                            // German "Ergebnis" and Russian "Результат", and
                            // deriving it from implicitContentWidth doesn't
                            // help either — headerSlot sizes from
                            // childrenRect, which doesn't re-evaluate when a
                            // child's implicit width is itself a binding.
                            // The natural button width is stable and fits.
                            leftPadding: 10
                            rightPadding: 10
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
                    RetouchOverlay {
                        parent: outputPane.contentArea
                        anchors.fill: parent
                        pane: outputPane.item
                        visible: Shell.retouchMode
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
                        color: theme.overlayCard
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
                                    color: theme.textSecondary
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Label {
                                    text: Shell.stageEta
                                    visible: text !== ""
                                    color: theme.textDim
                                    font.pixelSize: 12
                                }
                                Button {
                                    text: Shell.uiString("cancel")
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
                Label { text: Shell.uiString("zoomLabel"); color: theme.textSecondary; font.pixelSize: 12 }
                ToolButton {
                    id: zoomMenuButton
                    text: (outputPane.item.fitted ? Shell.uiString("zoomFit")
                          : Math.round(outputPane.item.displayScale * 100)
                            + "%") + "  ⌵"
                    font.pixelSize: 12
                    onClicked: zoomMenu.open()
                    Menu {
                        id: zoomMenu
                        y: -implicitHeight - 4
                        MenuItem { text: Shell.uiString("zoomFit"); onTriggered: outputPane.item.fit() }
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
