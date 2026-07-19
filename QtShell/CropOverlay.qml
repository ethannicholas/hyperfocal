// Interactive crop overlay over the output pane — the native
// CropOverlayNSView's geometry (ContentView.swift:1986-2276) ported to
// QML: dimmed surround, rotated border, 8 resize handles; drags for
// move/resize/rotate computed in canvas pixels and pushed through
// Shell.setCrop, with corner containment ("fits") as the universal
// gate. Geometry authority beyond the drag itself (aspect reshape,
// orientation swap, accept/cancel/undo, min-size backstop) stays in the
// model behind the crop-mode bridge calls.
import QtQuick
import Hyperfocal

Item {
    id: overlay
    required property PaneItem pane

    property real canvasW: 0
    property real canvasH: 0
    property rect crop: Qt.rect(0, 0, 0, 0)
    property real angle: 0

    // Drag state (canvas px unless noted)
    property int mode: 0            // 0 none, 1 move, 2 resize, 3 rotate
    property point startPoint: Qt.point(0, 0)
    property rect startRect: Qt.rect(0, 0, 0, 0)
    property point handleDir: Qt.point(0, 0)
    property point lastVec: Qt.point(0, 0)
    property real rotationTarget: 0

    function sync() {
        var r = Shell.editCrop()
        crop = Qt.rect(r.x, r.y, r.width, r.height)
        angle = Shell.editCropAngle()
        canvasW = Shell.displayWidth()
        canvasH = Shell.displayHeight()
        paint.requestPaint()
    }

    Connections {
        target: Shell
        function onChanged() { overlay.sync() }
    }
    Connections {
        // Pan/zoom moves the image under the overlay; everything here
        // is derived from pane.mapFromCanvas at paint time, so a
        // repaint re-anchors the dim + rect + handles.
        target: overlay.pane
        function onViewportChanged() { paint.requestPaint() }
    }
    onVisibleChanged: if (visible) sync()

    function push() {
        Shell.setCrop(crop.x, crop.y, crop.width, crop.height, angle)
        paint.requestPaint()
    }

    // Every rotated corner must lie inside the canvas (±0.5 slack) —
    // the native fits() gate (ContentView.swift:1886-1902).
    function fits(r, ang) {
        var rad = ang * Math.PI / 180
        var c = Math.cos(rad), s = Math.sin(rad)
        var cx = r.x + r.width / 2, cy = r.y + r.height / 2
        var corners = [[-r.width / 2, -r.height / 2],
                       [r.width / 2, -r.height / 2],
                       [-r.width / 2, r.height / 2],
                       [r.width / 2, r.height / 2]]
        for (var i = 0; i < 4; ++i) {
            var x = cx + corners[i][0] * c - corners[i][1] * s
            var y = cy + corners[i][0] * s + corners[i][1] * c
            if (x < -0.5 || x > canvasW + 0.5 || y < -0.5 || y > canvasH + 0.5)
                return false
        }
        return true
    }

    function normAngle(a) {
        while (a > 180) a -= 360
        while (a <= -180) a += 360
        return a
    }

    // Handle outward directions, the native ordering.
    readonly property var handles: [[-1, -1], [0, -1], [1, -1], [-1, 0],
                                    [1, 0], [-1, 1], [0, 1], [1, 1]]

    function paneScale() {
        var a = pane.mapFromCanvas(Qt.point(0, 0))
        var b = pane.mapFromCanvas(Qt.point(1, 0))
        return b.x - a.x
    }

    Canvas {
        id: paint
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (overlay.canvasW <= 0 || overlay.crop.width <= 0) return
            var s = overlay.paneScale()
            var c = pane.mapFromCanvas(Qt.point(
                overlay.crop.x + overlay.crop.width / 2,
                overlay.crop.y + overlay.crop.height / 2))
            var hw = overlay.crop.width / 2 * s
            var hh = overlay.crop.height / 2 * s
            var rad = overlay.angle * Math.PI / 180

            // Dim the CANVAS outside the rotated rect (even-odd fill)
            // — the letterbox around the image stays black, like native
            // (its outer path is the canvas rect, not the view).
            var o = pane.mapFromCanvas(Qt.point(0, 0))
            ctx.beginPath()
            ctx.rect(o.x, o.y, overlay.canvasW * s, overlay.canvasH * s)
            var poly = []
            for (var i = 0; i < 4; ++i) {
                var px = [-hw, hw, hw, -hw][i]
                var py = [-hh, -hh, hh, hh][i]
                poly.push([c.x + px * Math.cos(rad) - py * Math.sin(rad),
                           c.y + px * Math.sin(rad) + py * Math.cos(rad)])
            }
            ctx.moveTo(poly[0][0], poly[0][1])
            ctx.lineTo(poly[3][0], poly[3][1])
            ctx.lineTo(poly[2][0], poly[2][1])
            ctx.lineTo(poly[1][0], poly[1][1])
            ctx.closePath()
            ctx.fillStyle = Qt.rgba(0.5, 0.5, 0.5, 0.55)
            ctx.fill("evenodd")

            // Border + handles in the rotated local frame, screen-sized
            // like native (8×8 handles regardless of zoom).
            ctx.save()
            ctx.translate(c.x, c.y)
            ctx.rotate(rad)
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.9)
            ctx.lineWidth = 1
            ctx.strokeRect(-hw + 0.5, -hh + 0.5, 2 * hw - 1, 2 * hh - 1)
            ctx.fillStyle = Qt.rgba(1, 1, 1, 0.9)
            for (var j = 0; j < overlay.handles.length; ++j) {
                var hx = overlay.handles[j][0] * hw
                var hy = overlay.handles[j][1] * hh
                ctx.fillRect(hx - 4, hy - 4, 8, 8)
            }
            ctx.restore()
        }
    }

    // Classify a pane-space point: {mode, hx, hy} in the rotated local
    // SCREEN frame so the handle tolerance (8px + 4px margin) is
    // zoom-independent.
    function classify(px, py) {
        var s = paneScale()
        var cx = crop.x + crop.width / 2
        var cy = crop.y + crop.height / 2
        var cPane = pane.mapFromCanvas(Qt.point(cx, cy))
        var rad = angle * Math.PI / 180
        var dx = px - cPane.x, dy = py - cPane.y
        var lx = dx * Math.cos(rad) + dy * Math.sin(rad)
        var ly = -dx * Math.sin(rad) + dy * Math.cos(rad)
        var hw = crop.width / 2 * s
        var hh = crop.height / 2 * s
        for (var i = 0; i < handles.length; ++i) {
            var hx = handles[i][0], hy = handles[i][1]
            if (Math.abs(lx - hx * hw) <= 8 && Math.abs(ly - hy * hh) <= 8)
                return { mode: 2, hx: hx, hy: hy }
        }
        return { mode: (Math.abs(lx) <= hw && Math.abs(ly) <= hh) ? 1 : 3,
                 hx: 0, hy: 0 }
    }

    // Directional resize cursor for a handle: quantize the handle's
    // outward direction AFTER rotation into the four built-in resize
    // axes (the native 8-sector scheme, folded onto Qt's cursor pairs).
    function resizeCursor(hx, hy) {
        var rad = angle * Math.PI / 180
        var sx = hx * Math.cos(rad) - hy * Math.sin(rad)
        var sy = hx * Math.sin(rad) + hy * Math.cos(rad)
        var sector = Math.round(Math.atan2(sy, sx) / (Math.PI / 4))
        sector = ((sector % 4) + 4) % 4
        return sector === 0 ? Qt.SizeHorCursor
             : sector === 1 ? Qt.SizeFDiagCursor
             : sector === 2 ? Qt.SizeVerCursor
             : Qt.SizeBDiagCursor
    }

    property int hoverMode: 0
    property point hoverDir: Qt.point(0, 0)

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: {
            var m = overlay.mode !== 0 ? overlay.mode : overlay.hoverMode
            var d = overlay.mode !== 0 ? overlay.handleDir : overlay.hoverDir
            // Move and rotate share the hand pair: open on hover,
            // closed while dragging.
            return m === 2 ? overlay.resizeCursor(d.x, d.y)
                 : m === 0 ? Qt.ArrowCursor
                 : overlay.mode !== 0 ? Qt.ClosedHandCursor
                                      : Qt.OpenHandCursor
        }

        onPressed: function(mouse) {
            var raw = pane.mapToCanvas(Qt.point(mouse.x, mouse.y))
            overlay.startPoint = raw
            overlay.startRect = Qt.rect(overlay.crop.x, overlay.crop.y,
                                        overlay.crop.width, overlay.crop.height)
            overlay.rotationTarget = overlay.angle
            var cx = overlay.crop.x + overlay.crop.width / 2
            var cy = overlay.crop.y + overlay.crop.height / 2
            overlay.lastVec = Qt.point(raw.x - cx, raw.y - cy)
            var hit = overlay.classify(mouse.x, mouse.y)
            overlay.mode = hit.mode
            overlay.handleDir = Qt.point(hit.hx, hit.hy)
        }
        onReleased: overlay.mode = 0

        onPositionChanged: function(mouse) {
            if (overlay.mode === 0) {
                // Hover: track the region under the pointer so the
                // cursor previews the drag it would start.
                var hit = overlay.classify(mouse.x, mouse.y)
                overlay.hoverMode = hit.mode
                overlay.hoverDir = Qt.point(hit.hx, hit.hy)
                return
            }
            var raw = pane.mapToCanvas(Qt.point(mouse.x, mouse.y))
            var rad = overlay.angle * Math.PI / 180
            var cosA = Math.cos(rad), sinA = Math.sin(rad)
            var W = overlay.startRect.width, H = overlay.startRect.height

            if (overlay.mode === 1) {
                // Move: translate, then clamp the rotated bbox per axis,
                // rounding toward the interior (native 2199-2228).
                var nx = overlay.startRect.x + raw.x - overlay.startPoint.x
                var ny = overlay.startRect.y + raw.y - overlay.startPoint.y
                var hw2 = W / 2 * Math.abs(cosA) + H / 2 * Math.abs(sinA)
                var hh2 = W / 2 * Math.abs(sinA) + H / 2 * Math.abs(cosA)
                var cx2 = Math.min(Math.max(nx + W / 2, hw2),
                                   overlay.canvasW - hw2)
                var cy2 = Math.min(Math.max(ny + H / 2, hh2),
                                   overlay.canvasH - hh2)
                // Round the origin toward the interior — .integral-style
                // outward rounding strands fast drags at the edge.
                var rx = Math.min(Math.max(Math.round(cx2 - W / 2),
                                           Math.ceil(hw2 - W / 2)),
                                  Math.floor(overlay.canvasW - hw2 - W / 2))
                var ry = Math.min(Math.max(Math.round(cy2 - H / 2),
                                           Math.ceil(hh2 - H / 2)),
                                  Math.floor(overlay.canvasH - hh2 - H / 2))
                var cand = Qt.rect(rx, ry, W, H)
                if (overlay.fits(cand, overlay.angle)) {
                    overlay.crop = cand
                    overlay.push()
                }
            } else if (overlay.mode === 2) {
                // Resize about the fixed opposite anchor in the rotated
                // frame (native 2229-2269); commit only when it fits.
                var hx = overlay.handleDir.x, hy = overlay.handleDir.y
                var scx = overlay.startRect.x + W / 2
                var scy = overlay.startRect.y + H / 2
                var alx = -hx * W / 2, aly = -hy * H / 2
                var ax = scx + alx * cosA - aly * sinA
                var ay = scy + alx * sinA + aly * cosA
                var vx = raw.x - ax, vy = raw.y - ay
                var lx2 = vx * cosA + vy * sinA
                var ly2 = -vx * sinA + vy * cosA
                var newW = hx === 0 ? W : Math.max(hx * lx2, 32)
                var newH = hy === 0 ? H : Math.max(hy * ly2, 32)
                var aspect = Shell.cropAspectRatio
                if (aspect > 0) {
                    if (hy === 0) newH = newW / aspect
                    else if (hx === 0) newW = newH * aspect
                    else if (Math.abs(newW - W) >= Math.abs(newH - H))
                        newH = newW / aspect
                    else newW = newH * aspect
                }
                var clx = hx * newW / 2, cly = hy * newH / 2
                var ncx = ax + clx * cosA - cly * sinA
                var ncy = ay + clx * sinA + cly * cosA
                var cand2 = Qt.rect(Math.round(ncx - newW / 2),
                                    Math.round(ncy - newH / 2),
                                    Math.round(newW), Math.round(newH))
                if (overlay.fits(cand2, overlay.angle)) {
                    overlay.crop = cand2
                    overlay.push()
                }
            } else {
                // Rotate about the center: incremental unwrapped angle,
                // bisecting toward a containment stop (native 2155-2198).
                var cx3 = overlay.crop.x + overlay.crop.width / 2
                var cy3 = overlay.crop.y + overlay.crop.height / 2
                var vec = Qt.point(raw.x - cx3, raw.y - cy3)
                var cross = overlay.lastVec.x * vec.y - overlay.lastVec.y * vec.x
                var dot = overlay.lastVec.x * vec.x + overlay.lastVec.y * vec.y
                overlay.rotationTarget += Math.atan2(cross, dot) * 180 / Math.PI
                overlay.lastVec = vec
                var target = overlay.normAngle(overlay.rotationTarget)
                if (overlay.fits(overlay.crop, target)) {
                    overlay.angle = target
                    overlay.push()
                } else {
                    var lo = overlay.angle, hi = target
                    for (var k = 0; k < 20; ++k) {
                        var mid = (lo + hi) / 2
                        if (overlay.fits(overlay.crop, mid)) lo = mid
                        else hi = mid
                    }
                    overlay.angle = lo
                    overlay.push()
                }
            }
        }
    }
}
