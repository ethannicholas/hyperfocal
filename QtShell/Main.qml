// Walking-skeleton window: open → fuse (progress) → pane (pan/zoom) →
// exposure → export. Deliberately spartan — this proves the bridge, not
// the chrome; the real shell mirrors the native app feature-by-feature.
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Hyperfocal

ApplicationWindow {
    id: window
    width: 1100
    height: 760
    visible: true
    title: "Hyperfocal (Qt shell — dev)"
    color: "#1b1b1b"

    Connections {
        target: Shell
        function onChanged() { pane.refresh() }
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

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Button {
                text: "Open Stack…"
                enabled: !Shell.isRunning
                onClicked: openDialog.open()
            }
            Button {
                text: "Fuse"
                enabled: Shell.canFuse
                onClicked: Shell.fuse()
            }
            ProgressBar {
                Layout.preferredWidth: 180
                visible: Shell.isRunning
                value: Shell.stageFraction
            }
            Label {
                text: Shell.stageText
                color: "#b5b5b5"
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Label { text: "Exposure"; color: "#b5b5b5" }
            Slider {
                id: exposureSlider
                from: -5
                to: 5
                value: Shell.exposure
                Layout.preferredWidth: 160
                onMoved: Shell.exposure = value
            }
            Label {
                text: exposureSlider.value.toFixed(2) + " EV"
                color: "#b5b5b5"
                font.family: "Menlo"
            }
            Button {
                text: "Export…"
                enabled: !Shell.isRunning
                onClicked: exportDialog.open()
            }
        }

        Pane {
            Layout.fillWidth: true
            Layout.fillHeight: true
            padding: 0
            background: Rectangle { color: "black" }

            PaneItem {
                id: pane
                anchors.fill: parent
            }
        }
    }
}
