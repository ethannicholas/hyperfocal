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

    MouseArea {
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
