// Phase 2 shell: sidebar (stack list, fusion sliders, fuse, tone, export)
// + output pane with Result/Depth toggle — mirroring the native app's
// layout so the two can be compared side-by-side on one machine. Still
// deliberately spartan; it proves the bridge surface, not the chrome.
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
// MultiEffect (part of qtdeclarative): rounds the stack thumbnails'
// corners via a mask — QML has no clipping-to-radius without it.
import QtQuick.Effects
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
    // Project name in the titlebar, the native document-window look
    // (neither shell shows a dirty marker; the quit gate still asks).
    title: {
        var name = "Hyperfocal"
        if (Shell.projectPath !== "") {
            var parts = Shell.projectPath.split("/")
            name = parts[parts.length - 1].replace(/\.hyperfocal$/, "")
        }
        return name
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
        // Monospace family per platform (Menlo is macOS-only; its Windows
        // fallback rendered wide).
        readonly property string monoFamily:
            Qt.platform.os === "osx" ? "Menlo"
            : Qt.platform.os === "windows" ? "Consolas" : "monospace"
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
            // The native View menu's zoom items (the shortcuts are bound
            // window-wide below; these are the discoverable menu entries).
            title: qsTr("View")
            Action {
                text: qsTr("Zoom In")
                shortcut: StandardKey.ZoomIn
                onTriggered: outputPane.item.zoomBy(1.5)
            }
            Action {
                text: qsTr("Zoom Out")
                shortcut: StandardKey.ZoomOut
                onTriggered: outputPane.item.zoomBy(1 / 1.5)
            }
            Action {
                text: qsTr("Zoom to Fit")
                shortcut: "Ctrl+0"
                onTriggered: outputPane.item.fit()
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

    // Sidebar/preview hairline + grab strip, the native SidebarSplitter:
    // dragging resizes the sidebar (280–360); the width persists through
    // the shared "sidebarWidth" settings key on release. The strip
    // overlays both panes, centered on the hairline, and sits above them
    // so the pane's own event handlers can't swallow the drag.
    Rectangle {
        x: sidebarScroll.width
        width: 1
        height: parent.height
        z: 40
        color: theme.cardBorder
    }
    MouseArea {
        x: sidebarScroll.width - width / 2
        width: 9
        height: parent.height
        z: 50
        cursorShape: Qt.SplitHCursor
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        onPositionChanged: function(mouse) {
            if (!pressed) return
            // Scene x IS the candidate width (the sidebar starts at 0).
            var sceneX = mapToItem(null, mouse.x, 0).x
            sidebarScroll.sidebarWidth = Math.min(Math.max(sceneX, 280), 360)
        }
        onReleased: Shell.setSidebarWidth(sidebarScroll.sidebarWidth)
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
    // A replaced project (New Project, Open, Close) must not inherit the
    // previous one's scroll offset — reset the stack panel to its start,
    // anchoring a restored selection's stack like native's generation-
    // keyed scroll. Deferred a tick so the fresh model's delegates exist,
    // which also queues this after scrollSelectedFrameIntoView's own
    // callLater from the same refresh — the project reset wins.
    function scrollToProjectStart() {
        Qt.callLater(function() {
            if (stackList.count > 1 && Shell.selectedStack > 0)
                stackList.positionViewAtIndex(Shell.selectedStack,
                                              ListView.Beginning)
            else
                stackList.positionViewAtBeginning()
            frameList.positionViewAtBeginning()
        })
    }
    Connections {
        target: Shell
        function onFramesChanged() { scrollSelectedFrameIntoView() }
        function onStacksChanged() { scrollSelectedFrameIntoView() }
        function onProjectGenerationChanged() { scrollToProjectStart() }
    }

    // The native ⌘Z family; menu entries with the mode-scoped titles arrive
    // with the menu bar. These look like duplicates of the Edit menu's
    // Actions and are not: `sequences: [StandardKey.Undo]` binds EVERY
    // platform binding, while the Action's `shortcut: StandardKey.Undo`
    // binds only the first — Qt warns about exactly that. Measured on
    // Windows/Qt 6.10: Undo has 3 bindings there and Redo 4, so dropping
    // these would narrow undo/redo to Ctrl+Z / Ctrl+Y alone.
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
    // Zoom shortcuts (⌘+/⌘−/⌘0; Ctrl elsewhere) live on the View menu's
    // Actions above, and one loose Shortcut per sequence would be
    // harmless: a menu Action and a loose Shortcut on the SAME sequence
    // do NOT resolve as ambiguous — measured on Windows/Qt 6.10 with a
    // two-loose-Shortcuts positive control, the Action wins and fires
    // exactly once, in either declaration order. (Two *loose* Shortcuts
    // on one sequence do go ambiguous and neither fires.)
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
        // The native About window, hand-built like AboutWindow.swift:
        // icon, name, version (build), repository link, the Third-Party
        // Notices link, and the copyright line.
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
                // All third-party attribution (including the Adobe DNG SDK
                // notice) lives behind this link rather than a menu item or
                // a credits paragraph: About is where users look for
                // disclosures, and no license requires them displayed here.
                objectName: "about.third-party-notices"
                text: "<a href=\"#notices\">"   // i18n-exempt: markup shell
                      + Shell.uiString("thirdPartyNotices") + "</a>"   // i18n-exempt: markup shell
                textFormat: Text.RichText
                font.pixelSize: 11
                Layout.alignment: Qt.AlignHCenter
                Accessible.role: Accessible.Link
                Accessible.name: Shell.uiString("thirdPartyNotices")
                onLinkActivated: {
                    aboutDialog.close()
                    noticesDialog.open()
                }
            }
            Label {
                text: "© 2026 Ethan Nicholas"   // i18n-exempt: a name
                color: theme.textDim
                font.pixelSize: 11
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    // Third-party notices + the full license texts, compiled into the
    // executable's resources so they are readable with no repo and no
    // writable install directory (the same files also ship beside the
    // executable — Scripts/package-windows.ps1 — which is what the LGPL
    // actually requires; this is the discoverable copy, and it works from a
    // Store install where the package directory is write-protected). Read
    // once per open: it is ~80 KB of text and nothing about it changes at
    // runtime. Two text areas: NOTICE.md renders as Markdown, the license
    // texts stay verbatim monospace (rendering would reflow them).
    Dialog {
        id: noticesDialog
        objectName: "about.third-party-notices"
        title: Shell.uiString("thirdPartyNotices")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Close
        width: Math.min(720, Math.max(360, window.width - 80))
        height: Math.min(560, Math.max(280, window.height - 80))
        onOpened: {
            if (noticesBody.text === "") {
                noticesBody.text = Shell.noticesMarkdown()
                licensesBody.text = Shell.licensesText()
            }
        }
        Flickable {
            anchors.fill: parent
            contentWidth: width
            contentHeight: noticesColumn.height
            clip: true
            ScrollBar.vertical: ScrollBar {}
            Column {
                id: noticesColumn
                width: parent.width
                TextArea {
                    id: noticesBody
                    width: parent.width
                    textFormat: TextEdit.MarkdownText
                    readOnly: true
                    wrapMode: TextArea.Wrap
                    selectByMouse: true
                    background: null
                    font.pixelSize: 12
                    Accessible.name: Shell.uiString("thirdPartyNotices")
                    // NOTICE.md's relative links (LICENSE, licenses/, vendored
                    // paths) point into the source tree, not the install;
                    // only real URLs are followable.
                    onLinkActivated: link => {
                        if (link.startsWith("http")) Qt.openUrlExternally(link)
                    }
                }
                TextArea {
                    id: licensesBody
                    width: parent.width
                    readOnly: true
                    wrapMode: TextArea.Wrap
                    selectByMouse: true
                    background: null
                    font.family: theme.monoFamily
                    font.pixelSize: 11
                }
            }
        }
    }

    Dialog {
        id: settingsDialog
        title: qsTr("Settings")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Close
        // Fixed width like the native settings window (480pt there):
        // the wrapped captions would otherwise stretch the dialog to
        // their unwrapped implicit width.
        width: 480
        onOpened: {
            orderToggle.checked = Shell.boolSetting("order-by-capture")
            alignToggle.checked = Shell.boolSetting("align")
            normalizeToggle.checked = Shell.boolSetting("normalize-exposure")
            gpuToggle.checked = Shell.boolSetting("gpu")
            diskToggle.checked = Shell.boolSetting("disk-cache")
        }
        // The native grouped Form: Loading / Fusion / Performance cards,
        // an explanatory caption under every toggle (SettingsView.swift
        // is the reference; the caption strings are shared catalog keys).
        ColumnLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            Label {
                text: qsTr("Loading")
                color: theme.textSecondary
                font.pixelSize: 11
                font.bold: true
                Layout.leftMargin: 4
            }
            SidebarCard {
                CheckBox {
                    id: orderToggle
                    objectName: "settings.order-by-capture"
                    text: Shell.uiString("settingsOrderByCaptureTime")
                    onToggled: Shell.setBoolSetting("order-by-capture", checked)
                }
                SettingCaption {
                    text: qsTr("Sorts each stack's frames by EXIF capture time when loading (filename order breaks when the camera's file counter rolls over mid-stack). Frames without timestamps fall back to filename order. Turn off to always order by filename.")
                }
            }
            Label {
                text: Shell.uiString("fusionSectionTitle")
                color: theme.textSecondary
                font.pixelSize: 11
                font.bold: true
                Layout.leftMargin: 4
                Layout.topMargin: 6
            }
            SidebarCard {
                CheckBox {
                    id: alignToggle
                    objectName: "settings.align"
                    text: Shell.uiString("settingsAlignFrames")
                    onToggled: Shell.setBoolSetting("align", checked)
                }
                SettingCaption {
                    text: qsTr("Register every frame to its neighbor before fusing (focus breathing, drift, rotation). Turn off only for stacks that are already pixel-aligned, e.g. re-exports from another tool.")
                }
                CheckBox {
                    id: normalizeToggle
                    objectName: "settings.normalize-exposure"
                    text: Shell.uiString("settingsEvenOutExposure")
                    onToggled: Shell.setBoolSetting("normalize-exposure", checked)
                }
                SettingCaption {
                    text: qsTr("Measures each frame's overall brightness and corrects shot-to-shot exposure flicker (shutter or lighting variation) before blending, so it can't imprint brightness patches on the result.")
                }
            }
            Label {
                text: qsTr("Performance")
                color: theme.textSecondary
                font.pixelSize: 11
                font.bold: true
                Layout.leftMargin: 4
                Layout.topMargin: 6
            }
            SidebarCard {
                CheckBox {
                    id: gpuToggle
                    objectName: "settings.gpu"
                    text: Shell.uiString("settingsUseGPU")
                    enabled: Shell.gpuAvailable()
                    onToggled: Shell.setBoolSetting("gpu", checked)
                }
                SettingCaption {
                    text: Shell.gpuAvailable()
                        ? qsTr("Fuse on the GPU (identical results, usually faster). Turn off to reduce memory pressure on low-RAM machines, free the GPU for other work, or rule out a driver issue.")
                        : qsTr("No usable GPU found — fusing runs on the CPU.")
                }
                CheckBox {
                    id: diskToggle
                    objectName: "settings.disk-cache"
                    text: Shell.uiString("settingsCacheFrames")
                    onToggled: Shell.setBoolSetting("disk-cache", checked)
                }
                SettingCaption {
                    text: qsTr("Keeps aligned frames in a temporary file during depth fusion so the stack isn't decoded twice (identical results, faster — the file needs about 0.7 GB of free disk per 45-megapixel frame and is removed when fusing finishes). Hyperfocal warns before fusing if it won't fit; turn off to never use the disk.")
                }
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
        // Default for ordinary tooltips (buttons, badges); the (i) info
        // icons override this with the shared cross-shell constant below.
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
        // (i) tips answer faster than ordinary tooltips — the delay is the
        // shared cross-shell constant (native's InfoTip.swift reads the
        // same value).
        InfoTip {
            parent: icon
            visible: iconHover.hovered
            text: icon.tip
            delay: Shell.infoTipDelayMs()
        }
    }

    // A settings caption: the explanatory line under each toggle in the
    // Settings dialog (native SettingsView's caption()).
    component SettingCaption: Label {
        Layout.fillWidth: true
        Layout.leftMargin: 6
        color: theme.textDim
        font.pixelSize: 11
        wrapMode: Text.WordWrap
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
                // Monospace keeps the value from jittering during drags.
                font.family: theme.monoFamily
            }
        }
        Slider {
            id: control
            // The shared control-id vocabulary (native accessibility
            // identifiers) as objectName, plus a spoken name.
            objectName: sliderRoot.sliderId
            Accessible.name: sliderRoot.label
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
        objectName: "section." + section
        Accessible.role: Accessible.Button
        Accessible.name: title
        Accessible.onPressAction: Shell.toggleSection(section)
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
            // Draggable width, the native hand-rolled splitter: opens at
            // the persisted value, clamped 280–360, and persists through
            // the shared "sidebarWidth" settings key on release. A plain
            // property (one startup read through the bridge), not a
            // binding — the drag drives it locally.
            property real sidebarWidth: Shell.sidebarWidth()
            Layout.preferredWidth: sidebarWidth
            Layout.minimumWidth: sidebarWidth
            Layout.maximumWidth: sidebarWidth
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
                // "N of M" included count at the right edge beside
                // All/None, the native stack.count placement.
                Label {
                    objectName: "stack.count"
                    visible: Shell.frames.length > 0
                    text: {
                        var n = 0
                        for (var i = 0; i < Shell.frames.length; ++i)
                            if (Shell.frames[i].included) ++n
                        return qsTr("%1 of %2").arg(n).arg(Shell.frames.length)
                    }
                    color: theme.textDim
                    font.pixelSize: 11
                }
                Button {
                    objectName: "stack.include-all"
                    text: Shell.uiString("includeAllFrames")
                    visible: frameList.count > 0 && !stackHeader.collapsed
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
                    objectName: "stack.include-none"
                    text: Shell.uiString("includeNoFrames")
                    visible: frameList.count > 0 && !stackHeader.collapsed
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
                        objectName: "stack.row." + stackDelegate.modelData.name
                                    + ".disclose"
                        Accessible.role: Accessible.Button
                        Accessible.name: stackDelegate.modelData.expanded
                            ? qsTr("Collapse %1").arg(stackDelegate.modelData.name)
                            : qsTr("Expand %1").arg(stackDelegate.modelData.name)
                        Accessible.onPressAction: Shell.setStackExpanded(
                            stackDelegate.index,
                            !stackDelegate.modelData.expanded)
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
                        objectName: "stack.row." + stackDelegate.modelData.name
                                    + ".enabled"
                        Accessible.name: qsTr("Include %1 in Fuse Enabled Stacks")
                                         .arg(stackDelegate.modelData.name)
                        checked: modelData.enabled
                        enabled: !Shell.isRunning
                        onToggled: Shell.setStackEnabled(index, checked)
                        HoverHandler { id: enabledHover }
                        InfoTip { parent: enabledCheckBox; visible: enabledHover.hovered; text: Shell.uiString("includeStackTip") }
                    }
                    Item {
                        // Middle-frame thumbnail, like native's stack rows.
                        // The 60×42 cell is always present: a placeholder
                        // glyph holds it while the thumbnail decodes, so
                        // the row doesn't reflow when the image lands
                        // (native holds the cell with square.stack.3d.up).
                        // thumbToken is 0 until the background generation
                        // lands, and cache-busts the URL when the source
                        // frame changes.
                        Layout.preferredWidth: 60
                        Layout.preferredHeight: 42
                        Canvas {
                            // Three stacked plates — the placeholder glyph
                            // (no SF Symbols off macOS, so it's drawn).
                            id: thumbPlaceholder
                            anchors.centerIn: parent
                            width: 24
                            height: 22
                            // Holds the cell until the image has really
                            // decoded — a failed or in-flight provider
                            // load must show the glyph, not a blank.
                            visible: thumbImage.status !== Image.Ready
                            property color glyphColor: theme.textFaint
                            onGlyphColorChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = String(glyphColor)
                                ctx.lineWidth = 1.2
                                ctx.lineJoin = "round"
                                for (var i = 0; i < 3; ++i) {
                                    var y = 5 + i * 6
                                    ctx.beginPath()
                                    ctx.moveTo(2, y)
                                    ctx.lineTo(12, y - 5)
                                    ctx.lineTo(22, y)
                                    ctx.lineTo(12, y + 5)
                                    ctx.closePath()
                                    ctx.stroke()
                                }
                            }
                        }
                        Image {
                            id: thumbImage
                            anchors.fill: parent
                            visible: false
                            source: stackDelegate.modelData.thumbToken !== 0
                                    ? "image://hfthumb/" + stackDelegate.index
                                      + "?" + stackDelegate.modelData.thumbToken
                                    : ""
                            sourceSize.width: 60
                            sourceSize.height: 42
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                        MultiEffect {
                            // Rounds the image's corners (native's 3pt
                            // clipShape) — QML can't clip to a radius
                            // without a mask pass.
                            anchors.fill: parent
                            visible: thumbImage.status === Image.Ready
                            source: thumbImage
                            maskEnabled: true
                            maskSource: thumbMask
                        }
                        Rectangle {
                            id: thumbMask
                            anchors.fill: parent
                            radius: 3
                            visible: false
                            layer.enabled: true
                        }
                        Rectangle {
                            // Native's hairline border over the rounding.
                            anchors.fill: parent
                            visible: thumbImage.status === Image.Ready
                            radius: 3
                            color: "transparent"
                            border.color: theme.cardBorder
                            border.width: 1
                        }
                    }
                    Label {
                        text: modelData.name
                        objectName: "stack.row." + stackDelegate.modelData.name
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Stack %1")
                                         .arg(stackDelegate.modelData.name)
                        Accessible.onPressAction: Shell.selectStack(stackDelegate.index)
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
                    // Row anatomy matches the flat list below: selection
                    // band, monospaced caption filename, hairline
                    // separator (native's List row treatment).
                    Repeater {
                        id: frameRepeater
                        model: stackDelegate.modelData.expanded
                               ? stackDelegate.modelData.frames : []
                        delegate: Item {
                            id: nestedFrameRow
                            required property int index
                            required property var modelData
                            readonly property bool selected:
                                stackDelegate.index === Shell.selectedStack
                                && Shell.selectedFrames.indexOf(index) !== -1
                            Layout.fillWidth: true
                            Layout.leftMargin: 28
                            implicitHeight: nestedRowContent.implicitHeight + 1
                            opacity: stackDelegate.modelData.enabled ? 1 : 0.4
                            enabled: stackDelegate.modelData.enabled
                            Rectangle {
                                anchors.fill: parent
                                anchors.bottomMargin: 1
                                radius: 4
                                color: nestedFrameRow.selected
                                       ? palette.highlight : "transparent"
                            }
                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: 1
                                color: theme.cardBorder
                            }
                            RowLayout {
                                id: nestedRowContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                spacing: 6
                                CheckBox {
                                    objectName: "frame.row."
                                        + nestedFrameRow.modelData.name + ".included"
                                    Accessible.name: qsTr("Include %1")
                                        .arg(nestedFrameRow.modelData.name)
                                    checked: nestedFrameRow.modelData.included
                                    enabled: !Shell.isRunning
                                    onToggled: Shell.setStackFrameIncluded(
                                        stackDelegate.index, nestedFrameRow.index, checked)
                                }
                                Label {
                                    // Click selects the frame, like the flat
                                    // list — the input pane follows (another
                                    // stack's frame switches stacks with it).
                                    text: nestedFrameRow.modelData.name
                                    objectName: "frame.row."
                                        + nestedFrameRow.modelData.name
                                    Accessible.role: Accessible.Button
                                    Accessible.name: nestedFrameRow.modelData.name
                                    Accessible.onPressAction: Shell.selectStackFrame(
                                        stackDelegate.index, nestedFrameRow.index)
                                    color: nestedFrameRow.selected ? palette.highlightedText
                                         : nestedFrameRow.modelData.included ? theme.textPrimary
                                                                             : theme.textFaint
                                    font.family: theme.monoFamily
                                    font.pixelSize: 11
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                    TapHandler {
                                        onTapped: Shell.selectStackFrame(
                                            stackDelegate.index, nestedFrameRow.index)
                                    }
                                }
                                Label {
                                    id: nestedIssueBadge
                                    text: "⚠"
                                    visible: nestedFrameRow.modelData.issue !== ""
                                    color: theme.warn
                                    HoverHandler { id: nestedIssueHover }
                                    InfoTip { parent: nestedIssueBadge; visible: nestedIssueHover.hovered; text: nestedFrameRow.modelData.issue }
                                }
                            }
                        }
                    }
                }
            }

            // Native empty state, only while no stack is open: hint and a
            // natural-width Open Folder…, both centered in a ~120pt block.
            ColumnLayout {
                visible: stackList.count === 0 && frameList.count === 0
                Layout.fillWidth: true
                Layout.minimumHeight: 120
                spacing: 10
                Item { Layout.fillHeight: true }
                Label {
                    Layout.fillWidth: true
                    text: Shell.uiString("dropFolderHint")
                    color: theme.textDim
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }
                Button {
                    objectName: "stack.open-folder"
                    Layout.alignment: Qt.AlignHCenter
                    text: Shell.uiString("openFolder")
                    enabled: !Shell.isRunning
                    onClicked: openDialog.open()
                }
                Item { Layout.fillHeight: true }
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
                // Row anatomy mirrors native's List rows: selection band,
                // monospaced caption filename, hairline separator.
                delegate: Item {
                    id: flatFrameRow
                    required property int index
                    required property var modelData
                    readonly property bool selected:
                        Shell.selectedFrames.indexOf(index) !== -1
                    width: frameList.width
                    implicitHeight: flatRowContent.implicitHeight + 1
                    Rectangle {
                        anchors.fill: parent
                        anchors.bottomMargin: 1
                        radius: 4
                        color: flatFrameRow.selected
                               ? palette.highlight : "transparent"
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: theme.cardBorder
                    }
                    RowLayout {
                        id: flatRowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 6
                        CheckBox {
                            objectName: "frame.row."
                                + flatFrameRow.modelData.name + ".included"
                            Accessible.name: qsTr("Include %1")
                                .arg(flatFrameRow.modelData.name)
                            checked: flatFrameRow.modelData.included
                            enabled: !Shell.isRunning
                            onToggled: Shell.setFrameIncluded(flatFrameRow.index, checked)
                        }
                        Label {
                            // Click selects the frame — the input pane follows.
                            text: flatFrameRow.modelData.name
                            objectName: "frame.row." + flatFrameRow.modelData.name
                            Accessible.role: Accessible.Button
                            Accessible.name: flatFrameRow.modelData.name
                            Accessible.onPressAction: Shell.selectFrame(flatFrameRow.index)
                            color: flatFrameRow.selected ? palette.highlightedText
                                 : flatFrameRow.modelData.included ? theme.textPrimary
                                                                   : theme.textFaint
                            font.family: theme.monoFamily
                            font.pixelSize: 11
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                            TapHandler { onTapped: Shell.selectFrame(flatFrameRow.index) }
                        }
                        Label {
                            id: issueBadge
                            // Fuse-time issue badge (misfire/misalignment).
                            text: "⚠"
                            visible: flatFrameRow.modelData.issue !== ""
                            color: theme.warn
                            HoverHandler { id: issueHover }
                            InfoTip { parent: issueBadge; visible: issueHover.hovered; text: flatFrameRow.modelData.issue }
                        }
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
                    objectName: "fusion.reset"
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
                                    objectName: "fusion.method." + modelData.key
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
                    objectName: "fusion.fuse-stack"
                    Layout.fillWidth: true
                    text: Shell.uiString("fuseStack")
                    enabled: Shell.canFuse
                    highlighted: true
                    onClicked: Shell.fuse()
                }
                Button {
                    id: fuseEnabledButton
                    objectName: "fusion.fuse-enabled"
                    Layout.fillWidth: true
                    // Shown only when more than one stack is *enabled*
                    // (the native rule) — with one enabled stack the plain
                    // Fuse button already covers it.
                    visible: {
                        var enabled = 0
                        for (var i = 0; i < Shell.stacks.length; ++i)
                            if (Shell.stacks[i].enabled) ++enabled
                        return enabled > 1
                    }
                    text: Shell.pendingStackCount === 1
                        ? qsTr("Fuse 1 Stack")
                        : qsTr("Fuse %1 Stacks").arg(Shell.pendingStackCount)
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
                    objectName: "tone.reset"
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
                    objectName: "edit.crop"
                    Layout.fillWidth: true
                    visible: !Shell.retouchMode && !Shell.cropMode
                    text: Shell.uiString("cropButton")
                    enabled: Shell.canCrop
                    onClicked: Shell.beginCrop()
                    HoverHandler { id: cropButtonHover }
                    InfoTip { parent: cropButton; visible: cropButtonHover.hovered; text: Shell.uiString("cropTip") }
                }
                Button {
                    objectName: "retouch.start"
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
                        objectName: "edit.crop-aspect"
                        Accessible.name: Shell.uiString("aspectRatioLabel")
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
                        objectName: "edit.crop-orientation"
                        // Icon-only control: the spoken name can't come
                        // from text, so it's set explicitly.
                        Accessible.name: qsTr("Swap Crop Orientation")
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
                        objectName: "edit.crop-accept"
                        Layout.fillWidth: true
                        highlighted: true
                        text: Shell.uiString("accept")
                        onClicked: Shell.acceptCrop()
                    }
                    Button {
                        objectName: "edit.crop-cancel"
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
                        objectName: "retouch.source-kind.frame"
                        text: Shell.uiString("retouchSourceImage")
                        checked: Shell.retouchSourceKind === 0
                        onClicked: Shell.retouchSourceKind = 0
                    }
                    RadioButton {
                        objectName: "retouch.source-kind.pmax"
                        text: Shell.uiString("retouchPMaxResult")
                        checked: Shell.retouchSourceKind === 1
                        onClicked: Shell.retouchSourceKind = 1
                    }
                    RadioButton {
                        objectName: "retouch.source-kind.dmap"
                        text: Shell.uiString("retouchDMapResult")
                        checked: Shell.retouchSourceKind === 2
                        onClicked: Shell.retouchSourceKind = 2
                    }
                }
                RowLayout {
                    visible: Shell.retouchMode
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Button {
                        objectName: "retouch.revert-all"
                        // Right-aligned at natural width — full-width would
                        // read as the section's primary action. Normal button
                        // colors: the macOS side's destructive role renders
                        // as a plain button there too (red is for menus and
                        // alerts), so a red label here would overstate it.
                        id: revertAllButton
                        enabled: Shell.retouchHasEdits
                        text: Shell.uiString("revertAll")
                        onClicked: Shell.revertRetouch()
                    }
                }
                Label {
                    // The native shortcut-hint caption under the retouch
                    // controls (Alt-scroll here — ⌥ is the Mac's key).
                    Layout.fillWidth: true
                    visible: Shell.retouchMode
                    text: qsTr("↑/↓ cycle source frames · space picks the sharpest frame for the brush region · p PMax result · r eraser · Alt-scroll or [ ] resize the brush · scroll/pinch to navigate")
                    color: theme.textDim
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
                Button {
                    objectName: "retouch.done"
                    Layout.fillWidth: true
                    visible: Shell.retouchMode
                    highlighted: true
                    text: Shell.uiString("doneRetouching")
                    onClicked: Shell.exitRetouch()
                }

            }
            }

            // Export flows directly after Edit, like the native form —
            // the spacer below it only soaks up leftover viewport height.
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
                    objectName: "export.result"
                    Layout.fillWidth: true
                    text: Shell.depthMode ? Shell.uiString("exportDepthMap") : Shell.uiString("exportResult")
                    enabled: !Shell.isRunning && Shell.hasDisplay
                    onClicked: Shell.exportInteractive()
                }
                Button {
                    id: exportAnimationButton
                    objectName: "export.animate"
                    Layout.fillWidth: true
                    // Always present, disabled until a depth-carrying
                    // result exists — the native enable rule.
                    text: Shell.uiString("exportRockingAnimation")
                    enabled: !Shell.isRunning && Shell.canAnimate
                    onClicked: Shell.exportAnimationInteractive()
                    HoverHandler { id: exportAnimationHover }
                    InfoTip { parent: exportAnimationButton; visible: exportAnimationHover.hovered; text: Shell.uiString("exportRockingAnimationTip") }
                }
                Button {
                    id: exportAllButton
                    objectName: "export.all"
                    Layout.fillWidth: true
                    visible: Shell.fusedStackCount > 1
                    text: Shell.uiString("exportAllFused")
                    enabled: !Shell.isRunning
                    onClicked: exportAllDialog.open()
                    HoverHandler { id: exportAllHover }
                    InfoTip { parent: exportAllButton; visible: exportAllHover.hovered; text: Shell.uiString("exportAllFusedTip") }
                }
            }
            }

            Item { Layout.fillHeight: true }
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
                            ? qsTr("Start a new project to begin")
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
                           ? qsTr("Retouched Depth — drag to paint from source")
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
                            objectName: "output.mode.result"
                            text: qsTr("Result")
                            checkable: true
                            autoExclusive: true
                            checked: !Shell.depthMode
                            // Greyed while no depth preview exists (e.g. a
                            // PMax-only result), like the native picker.
                            enabled: Shell.hasDepth
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
                            objectName: "output.mode.depth"
                            text: qsTr("Depth")
                            checkable: true
                            autoExclusive: true
                            checked: Shell.depthMode
                            enabled: Shell.hasDepth
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
                                objectName: "progress.bar"
                                Accessible.name: Shell.stageText
                                Layout.fillWidth: true
                                value: Shell.stageFraction
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Label {
                                    objectName: "progress.stage"
                                    text: Shell.stageText
                                    color: theme.textSecondary
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Label {
                                    objectName: "progress.eta"
                                    text: Shell.stageEta
                                    visible: text !== ""
                                    color: theme.textDim
                                    font.pixelSize: 12
                                }
                                Button {
                                    objectName: "progress.cancel"
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
            // Zoom: [Fit/N% ⌵] [−] [+] — a compact flat strip on the
            // header-bar material with a hairline above, like native's
            // .bar toolbar (Fusion's ToolButton renders as a large
            // filled block, so these are flat text buttons instead).
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: zoomRow.implicitHeight + 8
                color: theme.headerBar
                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: theme.cardBorder
                }
                RowLayout {
                    id: zoomRow
                    anchors.fill: parent
                    spacing: 8
                    Item { Layout.fillWidth: true }
                    Label { text: Shell.uiString("zoomLabel"); color: theme.textSecondary; font.pixelSize: 12 }
                    Button {
                        id: zoomMenuButton
                        objectName: "zoom.menu"
                        Accessible.name: qsTr("Zoom level")
                        flat: true
                        leftPadding: 6
                        rightPadding: 6
                        topPadding: 2
                        bottomPadding: 2
                        // Fixed width + monospaced digits (native pins the
                        // label at 60pt) so the −/+ buttons don't shift as
                        // Fit ↔ percentages swap through. Plain text, not a
                        // custom contentItem — the macOS native style
                        // rejects contentItem customization with a warning.
                        implicitWidth: 88
                        font.pixelSize: 12
                        font.family: theme.monoFamily
                        text: (outputPane.item.fitted
                               ? Shell.uiString("zoomFit")
                               : Math.round(outputPane.item.displayScale * 100)
                                 + "%") + " ⌵"
                        onClicked: zoomMenu.open()
                        Menu {
                            id: zoomMenu
                            y: -implicitHeight - 4
                            MenuItem { text: Shell.uiString("zoomFit"); onTriggered: outputPane.item.fit() }
                            // The native fixed levels (ViewportState.fixedLevels),
                            // all seven.
                            MenuItem { text: "6.25%"; onTriggered: outputPane.item.setAbsoluteScale(0.0625) }
                            MenuItem { text: "12.5%"; onTriggered: outputPane.item.setAbsoluteScale(0.125) }
                            MenuItem { text: "25%"; onTriggered: outputPane.item.setAbsoluteScale(0.25) }
                            MenuItem { text: "50%"; onTriggered: outputPane.item.setAbsoluteScale(0.5) }
                            MenuItem { text: "100%"; onTriggered: outputPane.item.setAbsoluteScale(1) }
                            MenuItem { text: "200%"; onTriggered: outputPane.item.setAbsoluteScale(2) }
                            MenuItem { text: "400%"; onTriggered: outputPane.item.setAbsoluteScale(4) }
                        }
                    }
                    Button {
                        objectName: "zoom.out"
                        Accessible.name: qsTr("Zoom out")
                        flat: true
                        text: "−"
                        font.pixelSize: 14
                        leftPadding: 8
                        rightPadding: 8
                        topPadding: 0
                        bottomPadding: 0
                        onClicked: outputPane.item.zoomBy(1 / 1.5)
                    }
                    Button {
                        objectName: "zoom.in"
                        Accessible.name: qsTr("Zoom in")
                        flat: true
                        text: "+"
                        font.pixelSize: 14
                        leftPadding: 8
                        rightPadding: 8
                        topPadding: 0
                        bottomPadding: 0
                        onClicked: outputPane.item.zoomBy(1.5)
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }
    }
}
