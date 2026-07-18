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

    component SidebarSlider: ColumnLayout {
        required property string sliderId
        required property string label
        required property real from
        required property real to
        property string format: "%1"
        spacing: 2
        Layout.fillWidth: true
        RowLayout {
            Layout.fillWidth: true
            Label { text: label; color: "#b5b5b5"; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            Label {
                text: format.arg(control.value.toFixed(2))
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

        // Sidebar
        ColumnLayout {
            Layout.preferredWidth: 280
            Layout.maximumWidth: 280
            Layout.fillHeight: true
            Layout.margins: 10
            spacing: 10

            Button {
                Layout.fillWidth: true
                text: "Open Stack…"
                enabled: !Shell.isRunning
                onClicked: openDialog.open()
            }

            Label { text: "Stack"; color: "#d5d5d5"; font.bold: true }
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
                        text: modelData.name
                        color: modelData.included ? "#d5d5d5" : "#777777"
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                }
            }

            Label { text: "Fusion"; color: "#d5d5d5"; font.bold: true }
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
            ProgressBar {
                Layout.fillWidth: true
                visible: Shell.isRunning
                value: Shell.stageFraction
            }
            Label {
                Layout.fillWidth: true
                visible: Shell.isRunning
                text: Shell.stageText
                color: "#b5b5b5"
                font.pixelSize: 12
                elide: Text.ElideRight
            }

            Label { text: "Tone"; color: "#d5d5d5"; font.bold: true }
            SidebarSlider {
                sliderId: "tone.slider.exposure"
                label: "Exposure"; from: -5; to: 5; format: "%1 EV"
            }
            SidebarSlider {
                sliderId: "tone.slider.contrast"
                label: "Contrast"; from: -1; to: 1
            }

            Item { Layout.fillHeight: true }

            Button {
                Layout.fillWidth: true
                text: "Export…"
                enabled: !Shell.isRunning
                onClicked: exportDialog.open()
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
}
