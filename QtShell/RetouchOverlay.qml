// Retouch event + brush-circle overlay over the output pane. All
// authority (stamps, undo tiles, depth co-paint, dead-drag) lives in
// the model's RetouchSession; this forwards strokes and hover in
// full-image pixels (both segment endpoints, so stamp spacing stays in
// Swift) and draws the two-ring brush circle only while a stroke would
// actually paint (the native canPaint rule).
import QtQuick
import Hyperfocal

Item {
    id: overlay
    required property PaneItem pane

    property point lastPoint: Qt.point(0, 0)

    BrushCircle {
        id: circle
        anchors.fill: parent
        pane: overlay.pane
        active: overlay.visible
    }
    onVisibleChanged: if (!visible) Shell.retouchHoverClear()

    Connections {
        target: overlay.pane
        function onViewportChanged() {
            // A two-finger pan slides the image under a stationary
            // mouse, so the stored image-space hover point is no longer
            // the pixel under the cursor. Re-derive it from the cursor's
            // screen position — the circle stays under the mouse and the
            // session targets what's actually beneath it (native rule).
            if (!overlay.visible) return
            var g = Shell.cursorScreenPos()
            var local = overlay.mapFromGlobal(g.x, g.y)
            if (!overlay.contains(local)) return
            var p = pane.mapToImage(local)
            Shell.retouchHover(p.x, p.y)
            if (mouse.pressed)
                overlay.lastPoint = p
            circle.sync()
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.CrossCursor

        onPressed: function(mouse) {
            var p = pane.mapToImage(Qt.point(mouse.x, mouse.y))
            overlay.lastPoint = p
            Shell.retouchHover(p.x, p.y)
            Shell.retouchStrokeBegin(p.x, p.y)
            circle.sync()
        }
        onPositionChanged: function(mouse) {
            var p = pane.mapToImage(Qt.point(mouse.x, mouse.y))
            Shell.retouchHover(p.x, p.y)
            if (pressed) {
                Shell.retouchStrokeMove(overlay.lastPoint.x,
                                        overlay.lastPoint.y, p.x, p.y)
                overlay.lastPoint = p
            }
            circle.sync()
        }
        onReleased: Shell.retouchStrokeEnd()
        onExited: {
            Shell.retouchHoverClear()
            circle.sync()
        }
        onWheel: function(wheel) {
            // ⌥-scroll resizes the brush (native pow(1.015, -deltaY));
            // plain scrolls fall through to the pane's pan/zoom.
            if (wheel.modifiers & Qt.AltModifier) {
                Shell.retouchAdjustBrush(
                    Math.pow(1.015, -wheel.angleDelta.y / 8))
                circle.sync()
                wheel.accepted = true
            } else {
                wheel.accepted = false
            }
        }
    }
}
