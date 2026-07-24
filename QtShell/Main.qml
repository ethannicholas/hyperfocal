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
        return name + (Shell.hasUnsavedWork ? " — Edited" : "")
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
            title: "File"
            Action {
                text: "New Project…"
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
                text: "Open Project…"
                shortcut: StandardKey.Open
                enabled: !Shell.isRunning
                onTriggered: openProjectDialog.open()
            }
            Action {
                text: "Add Stack Folder…"
                shortcut: "Ctrl+Shift+N"
                enabled: !Shell.isRunning
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
        Menu {
            title: "Help"
            Action {
                text: "Hyperfocal Help"
                shortcut: "Ctrl+?"
                // The server 301s http → https; link the final URL.
                onTriggered: Qt.openUrlExternally(
                    "https://ethannicholas.com/hyperfocal/tutorial.html")
            }
            Action {
                text: "About Hyperfocal"
                onTriggered: aboutDialog.open()
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
                text: "Version " + Shell.appVersion()
                      + " (" + Shell.appBuild() + ")"
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
                text: "Includes the Adobe DNG SDK (DNG technology under "
                      + "license by Adobe Systems Incorporated) and the Qt "
                      + "framework under the GNU LGPL v3, plus other "
                      + "open-source libraries. See NOTICE.md for all "
                      + "third-party credits and licenses."
                color: theme.textDim
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.preferredWidth: 300
                horizontalAlignment: Text.AlignHCenter
            }
            Label {
                text: "© 2026 Ethan Nicholas"
                color: theme.textDim
                font.pixelSize: 11
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

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
                color: "#c0282828"
                Spinner {
                    id: badge
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    color: "#e0e0e0"  // dark card regardless of scheme
                }
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
            id: valueRow
            Layout.fillWidth: true
            // The title flexes and elides; the value keeps its natural
            // width. With a fixed spacer instead, wider style fonts
            // (Fusion on Windows) overflowed the row and the value was
            // clipped at the sidebar edge.
            Label {
                text: label
                color: theme.textSecondary
                font.pixelSize: 12
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            Label {
                id: valueLabel
                text: format.arg(control.value.toFixed(decimals))
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
    // headers sit above the cards.
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

            // Stack tree (flat mirror): shown once a second stack exists,
            // like the native sidebar. Row click selects (stash/install);
            // the checkbox is the batch-fuse opt-in.
            Label {
                text: "Stacks"
                visible: stackList.count > 1
                color: theme.textPrimary
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
                        checked: modelData.enabled
                        enabled: !Shell.isRunning
                        onToggled: Shell.setStackEnabled(index, checked)
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
                        // Load-time frame-order warning badge.
                        text: "△"
                        visible: modelData.orderWarning !== ""
                        color: theme.warn
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
                        color: modelData.status === 3 ? theme.warn : theme.ok
                        ToolTip.visible: modelData.status === 3 && hover.hovered
                        ToolTip.text: modelData.failure
                        HoverHandler { id: hover }
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
                                           && index === Shell.selectedFrame
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                                TapHandler {
                                    onTapped: Shell.selectStackFrame(
                                        stackDelegate.index, index)
                                }
                            }
                            Label {
                                text: "⚠"
                                visible: modelData.issue !== ""
                                color: theme.warn
                                ToolTip.visible: nestedIssueHover.hovered
                                ToolTip.text: modelData.issue
                                HoverHandler { id: nestedIssueHover }
                            }
                        }
                    }
                }
            }

            SectionHeader {
                id: stackHeader
                title: "Stack"
                section: "stack"
                // "N of M" included count, the native stack.count.
                subtitle: {
                    if (Shell.frames.length === 0) return ""
                    var n = 0
                    for (var i = 0; i < Shell.frames.length; ++i)
                        if (Shell.frames[i].included) ++n
                    return n + " of " + Shell.frames.length
                }
                Button {
                    text: "All"
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
                    text: "None"
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
            // Native empty state: hint + Open Folder…, under the
            // Stack label, only while no stack is open.
            Label {
                Layout.fillWidth: true
                visible: stackList.count === 0 && frameList.count === 0
                         && !stackHeader.collapsed
                text: "Drop a folder of frames here, or:"
                color: theme.textDim
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
            Button {
                Layout.fillWidth: true
                visible: stackList.count === 0 && frameList.count === 0
                         && !stackHeader.collapsed
                text: "Open Folder…"
                enabled: !Shell.isRunning
                onClicked: openDialog.open()
            }
            ListView {
                id: frameList
                // Single-stack projects list frames flat; with several
                // stacks the tree's nested rows take over, like native.
                visible: stackList.count <= 1 && !stackHeader.collapsed
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
                        font.bold: index === Shell.selectedFrame
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        TapHandler { onTapped: Shell.selectFrame(index) }
                    }
                    Label {
                        // Fuse-time issue badge (misfire/misalignment).
                        text: "⚠"
                        visible: modelData.issue !== ""
                        color: theme.warn
                        ToolTip.visible: issueHover.hovered
                        ToolTip.text: modelData.issue
                        HoverHandler { id: issueHover }
                    }
                }
            }

            SectionHeader {
                id: fusionHeader
                title: "Fusion"
                section: "fusion"
                Button {
                    text: "Reset"
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
            SidebarCard {
                visible: !fusionHeader.collapsed
                // Algorithm selector: DMap (depth map) or PMax (pyramid
                // fusion), each with an info tooltip. Only DMap carries depth;
                // the persisted raw value is "dmap"/"pmax". Label on top with
                // the radios below, matching the SidebarSlider layout.
                Label {
                    text: "Algorithm:"; color: theme.textSecondary; font.pixelSize: 12
                }
                Repeater {
                    model: [
                        { key: "dmap", label: "DMap",
                          tip: "Depth-map fusion. The only mode with a depth map — needed for the depth view, rocking animation, and depth-aware retouching. Can misjudge where objects at different depths overlap." },
                        { key: "pmax", label: "PMax",
                          tip: "Pyramid fusion. Clean where depths overlap, but has no depth map (no depth view or rocking) and can bloom highlights, which the Debloom controls reduce." }
                    ]
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        RadioButton {
                            text: modelData.label
                            checked: Shell.fusionAlgorithm === modelData.key
                            enabled: !Shell.isRunning
                            onClicked: Shell.fusionAlgorithm = modelData.key
                            ToolTip.visible: hovered
                            ToolTip.text: modelData.tip
                        }
                        Label {
                            text: "ⓘ"; color: theme.textSecondary
                            HoverHandler { id: infoHover }
                            ToolTip.visible: infoHover.hovered
                            ToolTip.text: modelData.tip
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
                // DMap sliders (shown for the depth-map algorithm)
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.sharpness"
                    label: "Sharpness σ"; from: 1; to: 16; format: "%1 px"
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.noise-floor"
                    label: "Noise floor"; from: 0.01; to: 1
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.median-radius"
                    label: "Median radius"; from: 0; to: 32; format: "%1 px"
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm !== "pmax"
                    sliderId: "fusion.slider.blend-radius"
                    label: "Blend radius"; from: 0.75; to: 4
                    enabled: !Shell.isRunning
                }
                // PMax debloom sliders (shown for the pyramid-fusion algorithm)
                SidebarSlider {
                    visible: Shell.fusionAlgorithm === "pmax"
                    sliderId: "fusion.slider.debloom-levels"
                    label: "Debloom levels"; from: 0; to: 8; format: "%1"
                    enabled: !Shell.isRunning
                }
                SidebarSlider {
                    visible: Shell.fusionAlgorithm === "pmax"
                    sliderId: "fusion.slider.focus-threshold"
                    label: "Focus threshold"; from: 0; to: 0.3
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
            }

            SectionHeader {
                id: toneHeader
                title: "Tone"
                section: "tone"
                Button {
                    text: "Reset"
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
            SidebarCard {
                visible: !toneHeader.collapsed
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
            }

            SectionHeader {
                id: editHeader
                title: "Edit"
                section: "retouch"
            }
            SidebarCard {
                visible: !editHeader.collapsed
                Button {
                    Layout.fillWidth: true
                    visible: !Shell.retouchMode && !Shell.cropMode
                    text: "Crop…"
                    enabled: Shell.canCrop
                    onClicked: Shell.beginCrop()
                }
                Button {
                    Layout.fillWidth: true
                    visible: !Shell.retouchMode && !Shell.cropMode
                    text: Shell.retouchHasEdits ? "Continue Retouching"
                                                : "Start Retouching"
                    enabled: Shell.canRetouch
                    onClicked: Shell.enterRetouch()
                }

                // Crop-mode controls replace the Edit buttons, under a
                // "Crop" sub-header — the native CropControls placement.
                Label {
                    visible: Shell.cropMode
                    text: "Crop"; color: theme.textPrimary; font.bold: true
                }
                RowLayout {
                    visible: Shell.cropMode
                    Layout.fillWidth: true
                    Label { text: "Aspect Ratio"; color: theme.textSecondary }
                    ComboBox {
                        Layout.fillWidth: true
                        model: ["Original", "Custom", "1:1", "3:2", "5:4",
                                "4:3", "16:9"]
                        currentIndex: Math.max(0, model.indexOf(Shell.cropAspect))
                        onActivated: Shell.cropAspect = currentText
                    }
                    Button {
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
                        ToolTip.visible: hovered
                        ToolTip.text:
                            "Swap the crop between landscape and portrait (X)."
                    }
                }
                RowLayout {
                    visible: Shell.cropMode
                    Layout.fillWidth: true
                    Button {
                        Layout.fillWidth: true
                        highlighted: true
                        text: "Accept"
                        onClicked: Shell.acceptCrop()
                    }
                    Button {
                        Layout.fillWidth: true
                        text: "Cancel"
                        onClicked: Shell.cancelCrop()
                    }
                }

                Label {
                    visible: Shell.retouchMode
                    text: "Retouching"; color: theme.textPrimary; font.bold: true
                }
                SidebarSlider {
                    visible: Shell.retouchMode
                    sliderId: "retouch.slider.brush-size"
                    label: "Brush size"; from: 1; to: 800; decimals: 0
                    format: "%1 px"
                }
                SidebarSlider {
                    visible: Shell.retouchMode
                    sliderId: "retouch.slider.softness"
                    label: "Softness"; from: 0; to: 1
                }
                ColumnLayout {
                    visible: Shell.retouchMode
                    Layout.fillWidth: true
                    spacing: 2
                    Label {
                        text: "Retouch from"
                        color: theme.textSecondary
                        font.pixelSize: 12
                    }
                    RadioButton {
                        text: "Source Image"
                        checked: Shell.retouchSourceKind === 0
                        onClicked: Shell.retouchSourceKind = 0
                    }
                    RadioButton {
                        text: "PMax Result"
                        checked: Shell.retouchSourceKind === 1
                        onClicked: Shell.retouchSourceKind = 1
                    }
                    RadioButton {
                        text: "DMap Result"
                        checked: Shell.retouchSourceKind === 2
                        onClicked: Shell.retouchSourceKind = 2
                    }
                }
                Button {
                    Layout.fillWidth: true
                    visible: Shell.retouchMode
                    enabled: Shell.retouchHasEdits
                    text: "Revert All"
                    onClicked: Shell.revertRetouch()
                }
                Button {
                    Layout.fillWidth: true
                    visible: Shell.retouchMode
                    highlighted: true
                    text: "Done Retouching"
                    onClicked: Shell.exitRetouch()
                }

                Label {
                    Layout.fillWidth: true
                    visible: Shell.displayCrop.width > 0
                    text: "Cropped to " + Shell.displayCrop.width + "×"
                          + Shell.displayCrop.height
                          + (Shell.displayCropAngle !== 0
                             ? ", " + Shell.displayCropAngle.toFixed(1) + "°" : "")
                    color: theme.textDim
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            Item { Layout.fillHeight: true }

            SectionHeader {
                id: exportHeader
                title: "Export"
                section: "export"
            }
            SidebarCard {
                visible: !exportHeader.collapsed
                Button {
                    Layout.fillWidth: true
                    text: Shell.depthMode ? "Export Depth Map…" : "Export Result…"
                    enabled: !Shell.isRunning && Shell.hasDisplay
                    onClicked: Shell.exportInteractive()
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
                        ? "Source: " + Shell.retouchSourceName
                          + "   ↑/↓ cycle · space picks sharpest"
                        : Shell.inputTitle !== "" ? Shell.inputTitle
                                                  : "Input"
                    hint: Shell.hasInput ? ""
                        : Shell.frames.length === 0
                            ? "Open a stack to begin"
                            : "Select a frame in the Stack list"
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
                                : "Loading source…"
                        color: theme.textSecondary
                        font.pixelSize: 13
                        padding: 8
                        background: Rectangle { color: "#c0282828"; radius: 6 }
                    }
                }
                TonedPane {
                    id: outputPane
                    Layout.preferredWidth: 1
                    title: Shell.retouchMode
                        ? (Shell.depthMode
                           ? "Retouched Depth"
                           : "Retouched Output — drag to paint from source")
                        : "Output"
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
                Label { text: "Zoom:"; color: theme.textSecondary; font.pixelSize: 12 }
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
