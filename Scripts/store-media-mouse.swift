// Cursor placement for store-media captures (Scripts/store-media.py):
// warp the pointer to a global screen point (points, top-left origin) and
// post a real mouseMoved event so tracking areas fire — the app's brush
// circle and crosshair cursor follow mouse *events*, not the warp.
// Compiled on demand by the driver; posting needs Accessibility trust for
// the invoking terminal (same grant AX driving already uses).
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("usage: store-media-mouse <x> <y>\n".utf8))
    exit(2)
}
// Approach along a short path of real events: a lone teleported mouseMoved
// doesn't reliably fire tracking-area entered/cursor-rect updates, and the
// crosshair + brush circle are the whole point of the capture.
let target = CGPoint(x: x, y: y)
let start = CGPoint(x: x - 60, y: y - 60)
for step in 0...12 {
    let t = Double(step) / 12
    let p = CGPoint(x: start.x + (target.x - start.x) * t,
                    y: start.y + (target.y - start.y) * t)
    guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                             mouseCursorPosition: p, mouseButton: .left) else {
        FileHandle.standardError.write(Data("CGEvent creation failed\n".utf8))
        exit(1)
    }
    move.post(tap: .cghidEventTap)
    usleep(30_000)
}
