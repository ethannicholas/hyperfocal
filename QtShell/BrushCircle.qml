// The retouch brush cursor: two concentric rings (black under white,
// the native circle) at the session's hover point, radius in image
// pixels mapped to the pane's scale. Plain border rectangles — a
// full-pane Canvas repaint per mouse move measurably dragged stroke
// latency. Drawn only while a stroke would paint (canPaint) — shown on
// BOTH panes, like native.
import QtQuick
import Hyperfocal

Item {
    id: ring
    required property PaneItem pane
    property bool active: true
    property point center: Qt.point(0, 0)
    property real radius: 0
    property bool shown: false
    visible: active && shown

    function sync() {
        if (!active) { shown = false; return }
        if (Shell.retouchCanPaint() && Shell.retouchCursorValid()) {
            var c = Shell.retouchCursor()
            center = pane.mapFromImage(Qt.point(c.x, c.y))
            var a = pane.mapFromCanvas(Qt.point(0, 0))
            var b = pane.mapFromCanvas(Qt.point(1, 0))
            radius = Math.max(1, Shell.retouchBrushRadius() * (b.x - a.x))
            shown = true
        } else {
            shown = false
        }
    }

    Connections {
        target: Shell
        function onTick() { ring.sync() }
    }
    Connections {
        target: ring.pane
        function onViewportChanged() { ring.sync() }
    }
    onActiveChanged: sync()

    Rectangle {
        x: ring.center.x - ring.radius - 1.5
        y: ring.center.y - ring.radius - 1.5
        width: ring.radius * 2 + 3
        height: width
        radius: width / 2
        color: "transparent"
        border.color: Qt.rgba(0, 0, 0, 0.8)
        border.width: 3
    }
    Rectangle {
        x: ring.center.x - ring.radius
        y: ring.center.y - ring.radius
        width: ring.radius * 2
        height: width
        radius: width / 2
        color: "transparent"
        border.color: Qt.rgba(1, 1, 1, 0.9)
        border.width: 1.5
    }
}
